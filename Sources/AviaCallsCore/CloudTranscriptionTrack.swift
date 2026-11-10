import AVFoundation
import CryptoKit
import Foundation

/// Ограниченные куски аудио с перекрытием: слово принадлежит только одному куску по середине таймкода.
public struct TranscriptionAudioChunk: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var ownedStart: Double
    public var ownedEnd: Double

    public static func plan(duration: Double, seconds: Double = 120, overlap: Double = 1) -> [Self] {
        guard duration.isFinite, duration > 0, seconds.isFinite, seconds > 0,
              overlap.isFinite, overlap >= 0, overlap < seconds else { return [] }
        var chunks: [Self] = []
        var start = 0.0
        while start < duration {
            let end = min(duration, start + seconds)
            chunks.append(Self(start: max(0, start - overlap), end: min(duration, end + overlap),
                               ownedStart: start, ownedEnd: end))
            start = end
        }
        return chunks
    }

    public func place(_ words: [Word], offset: Double) -> [Word] {
        words.compactMap { word in
            let midpoint = start + (word.start + word.end) / 2
            guard midpoint >= ownedStart, midpoint < ownedEnd else { return nil }
            return Word(start: word.start + start + offset, end: word.end + start + offset,
                        text: word.text, p: word.p)
        }
    }
}

/// WAV создаётся только для одного куска, без модели и без чтения всей встречи в память.
public final class TranscriptionAudioReader {
    private let file: AVAudioFile
    public var duration: Double { Double(file.length) / file.processingFormat.sampleRate }

    public init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.processingFormat.channelCount == 1 else { throw AudioError.channels }
    }

    public func wav(start: Double, end: Double, muted: [MicrophoneMuteInterval] = []) throws -> Data {
        let rate = file.processingFormat.sampleRate
        let from = max(0, AVAudioFramePosition((start * rate).rounded()))
        let to = min(file.length, AVAudioFramePosition((end * rate).rounded()))
        guard to > from, to - from <= AVAudioFramePosition(rate * 124),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(to - from)) else {
            throw AudioError.range
        }
        file.framePosition = from
        try file.read(into: buffer, frameCount: AVAudioFrameCount(to - from))
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { throw AudioError.range }
        for interval in muted {
            let lower = max(0, min(Int(buffer.frameLength), Int(floor(interval.start * rate - Double(from)))))
            let upper = max(0, min(Int(buffer.frameLength), Int(ceil(interval.end * rate - Double(from)))))
            if lower < upper { for i in lower..<upper { samples[i] = 0 } }
        }
        let count = UInt32(buffer.frameLength) * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(count + 36); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(rate)); number(UInt32(rate) * 2)
        number(UInt16(2)); number(UInt16(16)); text("data"); number(count)
        data.append(Data(bytes: samples, count: Int(count)))
        return data
    }

    private enum AudioError: LocalizedError {
        case channels, range
        var errorDescription: String? {
            switch self {
            case .channels: return "Для расшифровки нужны отдельные моно-дорожки AviaCalls."
            case .range: return "Не удалось прочитать фрагмент аудиозаписи."
            }
        }
    }
}

/// Успешные ответы сохраняются сразу: повтор после сбоя использует уже оплаченные части.
public struct CloudTranscriptionTrack {
    public typealias Recognize = @Sendable (Data, Double) async throws -> OpenRouterTranscriber.Result
    private let recognize: Recognize

    public init(recognize: @escaping Recognize) { self.recognize = recognize }

    public func words(audio: URL, offset: Double, levels: [Float], model: String, language: String?,
                      store: MeetingStore) async throws -> [Word] {
        try Task.checkCancellation()
        let reader = try TranscriptionAudioReader(url: audio)
        let chunks = TranscriptionAudioChunk.plan(duration: reader.duration)
        let muted = audio.deletingPathExtension().lastPathComponent == "mic"
            ? MicrophoneMuteIntervals.intervals(timeline: try store.loadTimeline(), offset: offset, duration: reader.duration) : []
        var uploadLevels = levels
        for interval in muted {
            let from = max(0, Int(floor(interval.start / SilenceGate.frame)))
            let to = min(uploadLevels.count, Int(ceil(interval.end / SilenceGate.frame)))
            if from < to { for i in from..<to { uploadLevels[i] = 0 } }
        }
        let url = store.dir.appendingPathComponent("transcription-openrouter-\(audio.deletingPathExtension().lastPathComponent).json")
        // Содержимое, а не путь: одинаковый файл можно переименовать; изменённый звук нельзя взять из кеша.
        let identity = try fingerprint(audio)
        var cache = (try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url)))
            ?? Checkpoint(source: identity, model: model, language: language, offset: offset, chunks: chunks, muted: muted)
        if cache.version != 2 || cache.source != identity || cache.model != model || cache.language != language
            || cache.offset != offset || cache.chunks != chunks || cache.muted != muted {
            cache = Checkpoint(source: identity, model: model, language: language, offset: offset, chunks: chunks, muted: muted)
        }
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            if cache.completed[String(index)] != nil { continue }
            let from = max(0, Int(chunk.start / SilenceGate.frame))
            let to = min(uploadLevels.count, Int(ceil(chunk.end / SilenceGate.frame)))
            if from < to && !uploadLevels[from..<to].contains(where: { $0 >= SilenceGate.threshold }) {
                cache.completed[String(index)] = []
            } else {
                let data = try reader.wav(start: chunk.start, end: chunk.end, muted: muted)
                try Task.checkCancellation()
                try store.updateTranscriptionCost { $0.beginRequest() }
                let result: OpenRouterTranscriber.Result
                do { result = try await recognize(data, chunk.end - chunk.start) }
                catch {
                    let cost = (error as? OpenRouterTranscriber.Failure)?.cost
                    _ = try? store.updateTranscriptionCost { $0.add(cost) }
                    throw error
                }
                try store.updateTranscriptionCost { $0.add(result.cost) }
                cache.completed[String(index)] = chunk.place(result.words, offset: offset)
            }
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
        }
        return chunks.indices.flatMap { cache.completed[String($0)] ?? [] }.sorted { $0.start < $1.start }
    }

    private struct Checkpoint: Codable {
        var version = 2
        var source: String
        var model: String
        var language: String?
        var offset: Double
        var chunks: [TranscriptionAudioChunk]
        var muted: [MicrophoneMuteInterval]
        var completed: [String: [Word]] = [:]
    }

    private func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

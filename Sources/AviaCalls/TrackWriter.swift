import AVFoundation

/// Пишет дорожку в CAF 16 кГц моно int16: Whisper читает его без пересчёта, а файл переживает падение приложения.
final class TrackWriter {
    static let sampleRate = 16000.0
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "aviacalls.trackwriter")
    private let start: Date
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var written: Int64 = 0
    private var offset: Double?

    init(url: URL, start: Date) throws {
        self.start = start
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatInt16, interleaved: false)
    }

    var alive: Bool { queue.sync { offset != nil } }

    /// Буфер жив только на время вызова, поэтому пишем синхронно.
    func append(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        queue.sync { write(buffer, at: now) }
    }

    /// Закрывает файл; возвращает секунды от начала записи до первого звука дорожки.
    func close() -> Double {
        queue.sync {
            file = nil
            return offset ?? 0
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, at now: Date) {
        guard let file, buffer.frameLength > 0 else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let elapsed = now.timeIntervalSince(start)
        if offset == nil { offset = max(0, elapsed - duration) }

        // дыра после смены устройства: добиваем тишиной, иначе время в файле уедет относительно таймлайна
        let expected = Int64((elapsed - duration - offset!) * Self.sampleRate)
        if expected - written > Int64(Self.sampleRate / 2) { silence(expected - written, into: file) }

        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
            if buffer.format.channelCount > 1 { converter?.channelMap = [0] }
        }
        let capacity = AVAudioFrameCount(duration * Self.sampleRate) + 64
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0 else { return }
        try? file.write(from: out)
        written += Int64(out.frameLength)
    }

    private func silence(_ frames: Int64, into file: AVAudioFile) {
        var left = frames
        while left > 0 {
            let n = AVAudioFrameCount(min(left, 16000))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return }
            buf.frameLength = n   // буфер создаётся обнулённым
            try? file.write(from: buf)
            left -= Int64(n)
            written += Int64(n)
        }
    }
}

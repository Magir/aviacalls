import AVFoundation
import AviaCallsCore
import Foundation

enum Pipeline {
    /// Папка встречи → transcript.md. Если segments.json уже есть, Whisper не запускается — только заново подписываются имена.
    static func process(dir: URL, transcriber: Transcriber) async throws {
        let store = MeetingStore(existing: dir)
        // meeting.json может не быть, если приложение убили до первого сохранения
        let info = (try? store.loadInfo()) ?? MeetingInfo(title: nil, start: Date(), end: nil, participants: [], myName: nil,
                                                           namesRead: false, micOffset: 0, zoomOffset: 0)
        let timeline = try store.loadTimeline()

        let words: TrackWords
        if let saved = store.loadWords() {
            words = saved
        } else {
            words = TrackWords(mic: try await track("mic", offset: info.micOffset, store, transcriber),
                               zoom: try await track("zoom", offset: info.zoomOffset, store, transcriber))
            try store.save(words: words)
        }

        // запомненное имя годится, только если такой участник был на этой встрече; иначе вычисляем по микрофону
        var me = info.myName
        if me == nil || !info.participants.contains(me!) {
            if let inferred = Attributor.inferMe(timeline) {
                me = inferred
                UserDefaults.standard.set(inferred, forKey: "myName")
            }
        }
        let utterances = Attributor.attribute(mic: words.mic, zoom: words.zoom, timeline: timeline, myName: me ?? "Я")
        try store.save(transcript: TranscriptRenderer.render(title: info.title ?? "Встреча", start: info.start,
                                                             participants: info.participants, utterances: utterances))
        for name in ["mic", "zoom"] { compress(dir.appendingPathComponent("\(name).caf")) }
    }

    private static func track(_ name: String, offset: Double, _ store: MeetingStore, _ transcriber: Transcriber) async throws -> [Word] {
        let url = store.audioURL(name)
        return SilenceGate.keep(try await transcriber.words(audio: url, offset: offset), levels: try levels(of: url), offset: offset)
    }

    /// Громкость дорожки (RMS) по отсчётам длиной SilenceGate.frame.
    static func levels(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)   // читает во float, 1.0 — полная шкала
        let step = AVAudioFrameCount(file.processingFormat.sampleRate * SilenceGate.frame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step) else { return [] }
        var out: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: step)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            out.append((sum / Float(buffer.frameLength)).squareRoot())
        }
        return out
    }

    /// CAF → m4a системным afconvert; исходник удаляем только при успехе.
    private static func compress(_ caf: URL) {
        guard FileManager.default.fileExists(atPath: caf.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac", "-b", "32000", caf.path, caf.deletingPathExtension().appendingPathExtension("m4a").path]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        if process.terminationStatus == 0 { try? FileManager.default.removeItem(at: caf) }
    }
}

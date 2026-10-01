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
            words = TrackWords(mic: try await transcriber.words(audio: store.audioURL("mic"), offset: info.micOffset),
                               zoom: try await transcriber.words(audio: store.audioURL("zoom"), offset: info.zoomOffset))
            try store.save(words: words)
        }

        let utterances = Attributor.attribute(mic: words.mic, zoom: words.zoom, timeline: timeline, myName: info.myName ?? "Я")
        try store.save(transcript: TranscriptRenderer.render(title: info.title ?? "Встреча", start: info.start,
                                                             participants: info.participants, utterances: utterances))
        for name in ["mic", "zoom"] { compress(dir.appendingPathComponent("\(name).caf")) }
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

import Foundation
import Testing
@testable import AviaCallsCore

@Suite struct TranscriptRendererTests {
    @Test func rendersHeaderAndLines() {
        let text = TranscriptRenderer.render(
            title: "Sync", start: Date(timeIntervalSince1970: 0), participants: ["John Doe", "Ivan"],
            utterances: [Utterance(start: 763, speaker: "John Doe", text: "Hello everyone"), Utterance(start: 3725, speaker: "Ivan", text: "Привет")])
        #expect(text.hasPrefix("# Sync\n"))
        #expect(text.contains("Участники: John Doe, Ivan"))
        #expect(text.contains("[00:12:43] John Doe: Hello everyone\n"))
        #expect(text.contains("[01:02:05] Ivan: Привет\n"))
    }

    @Test func interleavesScreenshotsByTime() {
        let text = TranscriptRenderer.render(
            title: "Sync", start: Date(timeIntervalSince1970: 0), participants: ["Ann"],
            utterances: [Utterance(start: 10, speaker: "Ann", text: "раз"), Utterance(start: 100, speaker: "Ann", text: "два")],
            screenshots: [Screenshot(time: 50, path: "screens/00-00-50.jpg"), Screenshot(time: 200, path: "screens/00-03-20.jpg")])
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("[") }
        #expect(lines == ["[00:00:10] Ann: раз", "[00:00:50] (экран) screens/00-00-50.jpg", "[00:01:40] Ann: два", "[00:03:20] (экран) screens/00-03-20.jpg"])
    }
}

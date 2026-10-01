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
}

import Foundation
import Testing
@testable import AviaCallsCore

@Suite struct TranscriptCorrectionTests {
    private let source = "# Встреча\n\nУчастники: Алёна\n\n[00:00:01] Алёна: ну, ёлка и Avia Calls\n[00:00:02] (экран) screens/00-00-02.jpg\n[00:00:03] Bob: вторая ёлка\n"

    @Test func editsFullSegmentsAndPreservesMarkdown() throws {
        let document = TranscriptCorrection.Document(source)
        #expect(document.segments == [
            .init(id: 0, text: "ну, ёлка и Avia Calls"),
            .init(id: 1, text: "вторая ёлка"),
        ])
        let edited = [
            TranscriptCorrection.Segment(id: 0, text: "Ёлка и AviaCalls."),
            .init(id: 1, text: "Вторая ёлка."),
        ]
        #expect(try document.applying(edited) == "# Встреча\n\nУчастники: Алёна\n\n[00:00:01] Алёна: Ёлка и AviaCalls.\n[00:00:02] (экран) screens/00-00-02.jpg\n[00:00:03] Bob: Вторая ёлка.\n")
    }

    @Test func rejectsMissingDuplicateAndUnknownIDs() {
        let original = [TranscriptCorrection.Segment(id: 0, text: "один"), .init(id: 1, text: "два")]
        #expect(throws: TranscriptCorrection.ValidationError.incompleteSegments) {
            try TranscriptCorrection.validate([.init(id: 0, text: "Один")], for: original)
        }
        #expect(throws: TranscriptCorrection.ValidationError.duplicateSegment) {
            try TranscriptCorrection.validate([.init(id: 0, text: "Один"), .init(id: 0, text: "Ещё один")], for: original)
        }
        #expect(throws: TranscriptCorrection.ValidationError.unknownSegment) {
            try TranscriptCorrection.validate([.init(id: 0, text: "Один"), .init(id: 2, text: "Два")], for: original)
        }
    }

    @Test func assemblesReorderedResponseInOriginalOrder() throws {
        let document = TranscriptCorrection.Document("[00:00:01] A: первый\n[00:00:02] B: второй\n")
        #expect(try document.applying([.init(id: 1, text: "Второй."), .init(id: 0, text: "Первый.")]) == "[00:00:01] A: Первый.\n[00:00:02] B: Второй.\n")
    }

    @Test func rejectsUnsafeEmptyAndOverlongSegments() {
        let original = [TranscriptCorrection.Segment(id: 0, text: "коротко")]
        #expect(throws: TranscriptCorrection.ValidationError.emptySegment) {
            try TranscriptCorrection.validate([.init(id: 0, text: "   ")], for: original)
        }
        #expect(throws: TranscriptCorrection.ValidationError.invalidText) {
            try TranscriptCorrection.validate([.init(id: 0, text: "Перенос\nстроки")], for: original)
        }
        #expect(throws: TranscriptCorrection.ValidationError.invalidText) {
            try TranscriptCorrection.validate([.init(id: 0, text: "Табуляция\tтекста")], for: original)
        }
        for separator in ["\u{2028}", "\u{2029}"] {
            #expect(throws: TranscriptCorrection.ValidationError.invalidText) {
                try TranscriptCorrection.validate([.init(id: 0, text: "Разделитель\(separator)строки")], for: original)
            }
        }
        #expect(throws: TranscriptCorrection.ValidationError.segmentTooLong) {
            try TranscriptCorrection.validate([.init(id: 0, text: String(repeating: "а", count: 100))], for: original)
        }
    }

    @Test func splitsLongSpeechAtWhitespaceWithSeamsAndContinuationHints() throws {
        let speech = String(repeating: "😀 слово ", count: 1_500)
        let source = "[00:00:01] A:  \(speech)  \n"
        let document = TranscriptCorrection.Document(source)
        #expect(document.segments.count > 1)
        #expect(document.segments.allSatisfy { $0.text.count <= 4_000 && $0.text.utf8.count <= 8_000 })
        #expect(document.segments.first?.continuesPrevious == false)
        #expect(document.segments.first?.continuesNext == true)
        #expect(document.segments.last?.continuesPrevious == true)
        #expect(document.segments.last?.continuesNext == false)
        #expect(try document.applying(Array(document.segments.reversed())) == source)
    }

    @Test func keepsAnUnbrokenLongTokenWhole() throws {
        let token = String(repeating: "x", count: 9_000)
        let document = TranscriptCorrection.Document("[00:00:01] A: \(token)\n")
        #expect(document.segments == [.init(id: 0, text: token)])
        #expect(try document.applying(document.segments) == "[00:00:01] A: \(token)\n")
    }

    @Test func preservesCRLFSpeakersAndScreenLines() throws {
        let source = "# Встреча\r\n\r\n[00:00:01] Алёна: ёлка\r\n[00:00:02] (экран) screens/test.jpg\r\n"
        let document = TranscriptCorrection.Document(source)
        #expect(document.segments == [.init(id: 0, text: "ёлка")])
        #expect(Array(try document.applying([.init(id: 0, text: "Ёлка")]).utf8) == Array("# Встреча\r\n\r\n[00:00:01] Алёна: Ёлка\r\n[00:00:02] (экран) screens/test.jpg\r\n".utf8))
    }

    @Test func preservesLegacySpeakerParsingAndRendererMap() throws {
        let legacy = TranscriptCorrection.Document("[00:00:01] Команда: Арбита: Готово.\n")
        #expect(legacy.segments == [.init(id: 0, text: "Готово.")])
        #expect(try legacy.applying([.init(id: 0, text: "Готово!")]) == "[00:00:01] Команда: Арбита: Готово!\n")

        let speaker = "Команда: Арбита"
        let rendered = TranscriptRenderer.document(title: "Встреча", start: Date(timeIntervalSince1970: 0), participants: [speaker],
                                                   utterances: [.init(start: 1, speaker: speaker, text: "Арбита: продукт готов.")],
                                                   screenshots: [.init(time: 2, path: "screens/test.jpg")])
        let document = TranscriptCorrection.Document(rendered.text, speakers: rendered.speakers)
        #expect(document.segments.map(\.text) == ["Арбита: продукт готов."])
        #expect(try document.applying([.init(id: 0, text: "Орбита: продукт готов.")]).contains("[00:00:01] \(speaker): Орбита: продукт готов."))
    }

    @Test(arguments: ["Команда: Арбита", "(экран) Иван", "(экран)"])
    func rendererMapKeepsSpeakerNamesSeparate(speaker: String) throws {
        let rendered = TranscriptRenderer.document(title: "Встреча", start: Date(timeIntervalSince1970: 0), participants: [speaker],
                                                    utterances: [.init(start: 1, speaker: speaker, text: "Арбита: продукт готов.")],
                                                    screenshots: [.init(time: 2, path: "screens/test.jpg")])
        let document = TranscriptCorrection.Document(rendered.text, speakers: rendered.speakers)
        #expect(document.segments.map(\.text) == ["Арбита: продукт готов."])
        let corrected = try document.applying([.init(id: 0, text: "Орбита: продукт готов.")])
        #expect(corrected.contains("[00:00:01] \(speaker): Орбита: продукт готов."))
        #expect(corrected.contains("[00:00:02] (экран) screens/test.jpg"))
    }

    @Test func preservesAllSeamWhitespaceEvenWhenEditedTextIsTrimmed() throws {
        let speech = String(repeating: "слово", count: 799) + "   \t  продолжение"
        let source = "[00:00:01] A:  " + speech + "  \r\n"
        let document = TranscriptCorrection.Document(source)
        #expect(document.segments.count == 2)
        let edited = document.segments.map { TranscriptCorrection.Segment(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespaces)) }
        #expect(try document.applying(edited) == source)
        let withTab = TranscriptCorrection.Document("[00:00:01] A: текст\tдальше\n")
        #expect(try withTab.applying(withTab.segments) == withTab.source)
    }

    @Test func assemblesManyUnicodeSegments() throws {
        let source = (0..<1000).map { "[00:00:01] Алёна: ёлка \($0) и Avia Calls 👩🏽‍💻\r\n" }.joined()
        let document = TranscriptCorrection.Document(source)
        let edited = document.segments.map { TranscriptCorrection.Segment(id: $0.id,
            text: $0.text.replacingOccurrences(of: "ёлка", with: "Большая Ёлка").replacingOccurrences(of: "Avia Calls", with: "AviaCalls")) }
        #expect(try document.applying(Array(edited.reversed())) == source
            .replacingOccurrences(of: "ёлка", with: "Большая Ёлка").replacingOccurrences(of: "Avia Calls", with: "AviaCalls"))
    }

    @Test func savesCurrentCopyAndValidatesSpeakerMapHash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-correction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = "# Оригинал\n[00:00:01] Анна: ёлка\n"
        let originalURL = dir.appendingPathComponent("transcript.md")
        try original.write(to: originalURL, atomically: true, encoding: .utf8)
        try TranscriptCorrection.save("# Оригинал\n[00:00:01] Анна: Ёлка\n", source: original, in: dir)
        #expect(TranscriptCorrection.currentURL(in: dir) == dir.appendingPathComponent("transcript.corrected.md"))
        #expect(try String(contentsOf: originalURL, encoding: .utf8) == original)
        try TranscriptCorrection.saveSpeakers([3: "Анна"], source: original, in: dir)
        #expect(TranscriptCorrection.loadSpeakers(source: original, in: dir) == [3: "Анна"])
        #expect(TranscriptCorrection.loadSpeakers(source: original + "changed", in: dir).isEmpty)
        try (original + " ").write(to: originalURL, atomically: true, encoding: .utf8)
        #expect(TranscriptCorrection.currentURL(in: dir) == nil)
    }
}

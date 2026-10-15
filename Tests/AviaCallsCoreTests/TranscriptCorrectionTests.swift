import Foundation
import Testing
@testable import AviaCallsCore

private func correctionGlossary() -> Glossary {
    Glossary(entries: [Glossary.Entry(term: "AviaCalls", description: "приложение"), Glossary.Entry(term: "Ёлка", description: "дерево")])
}

@Suite struct TranscriptCorrectionTests {
    private let source = "# Встреча\n\nУчастники: Алёна\n\n[00:00:01] Алёна: ёлка и Avia Calls\n[00:00:02] (экран) screens/00-00-02.jpg\n[00:00:03] Bob: вторая ёлка\n"

    @Test func exposesOnlyUtteranceTextAndPreservesOtherMarkdown() throws {
        let document = TranscriptCorrection.Document(source)
        #expect(document.segments == [
            .init(id: 4, text: "ёлка и Avia Calls"),
            .init(id: 6, text: "вторая ёлка"),
        ])
        let corrected = try document.applying([
            .init(id: 4, original: "ёлка", replacement: "Ёлка", termIndex: 1),
            .init(id: 4, original: "Avia Calls", replacement: "AviaCalls", termIndex: 0),
        ], glossary: correctionGlossary())
        #expect(corrected == "# Встреча\n\nУчастники: Алёна\n\n[00:00:01] Алёна: Ёлка и AviaCalls\n[00:00:02] (экран) screens/00-00-02.jpg\n[00:00:03] Bob: вторая ёлка\n")
    }

    @Test func rejectsUnsafeOrAmbiguousChanges() {
        let document = TranscriptCorrection.Document(source)
        let glossary = correctionGlossary()
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 4, original: "нет", replacement: "да", termIndex: 0)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 4, original: "ёлка", replacement: "ёлка", termIndex: 1)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 4, original: "ёлка\n", replacement: "Ёлка", termIndex: 1)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 99, original: "ёлка", replacement: "Ёлка", termIndex: 1)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 4, original: "ёлка", replacement: "Ёлка", termIndex: 9)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([
                .init(id: 4, original: "ёлка и", replacement: "Ёлка и", termIndex: 1),
                .init(id: 4, original: "и Avia", replacement: "и avia", termIndex: 0),
            ], glossary: glossary)
        }
        let repeated = TranscriptCorrection.Document("[00:00:01] Ann: ёлка и ёлка\n")
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try repeated.applying([.init(id: 0, original: "ёлка", replacement: "Ёлка", termIndex: 1)], glossary: glossary)
        }
        let overlappingOccurrences = TranscriptCorrection.Document("[00:00:01] Ann: aaaa\n")
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try overlappingOccurrences.applying([.init(id: 0, original: "aa", replacement: "b", termIndex: 0)], glossary: glossary)
        }
    }

    @Test func savesSeparateCurrentCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-correction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = "# Оригинал\n[00:00:01] Анна: ёлка\n"
        let originalURL = dir.appendingPathComponent("transcript.md")
        try original.write(to: originalURL, atomically: true, encoding: .utf8)
        try TranscriptCorrection.save("# Оригинал\n[00:00:01] Анна: Ёлка\n", source: original, in: dir)
        let correctedURL = dir.appendingPathComponent("transcript.corrected.md")
        #expect(try String(contentsOf: originalURL, encoding: .utf8) == original)
        #expect(TranscriptCorrection.currentURL(in: dir) == correctedURL)
        try (original + " ").write(to: originalURL, atomically: true, encoding: .utf8)
        #expect(TranscriptCorrection.currentURL(in: dir) == nil)
    }

    @Test func preservesCRLFWhileCorrectingSpeech() throws {
        let source = "# Встреча\r\n\r\n[00:00:01] Алёна: ёлка\r\n[00:00:02] (экран) screens/test.jpg\r\n"
        let document = TranscriptCorrection.Document(source)
        #expect(document.segments == [.init(id: 2, text: "ёлка")])
        let corrected = try document.applying([.init(id: 2, original: "ёлка", replacement: "Ёлка", termIndex: 1)], glossary: correctionGlossary())
        #expect(Array(corrected.utf8) == Array(source.replacingOccurrences(of: "ёлка", with: "Ёлка").utf8))
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"])
    func rejectsEveryLineBreakInReplacement(_ newline: String) {
        let document = TranscriptCorrection.Document(source)
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 4, original: "ёлка", replacement: "Ёлка" + newline + "лишняя строка", termIndex: 1)], glossary: correctionGlossary())
        }
    }
}

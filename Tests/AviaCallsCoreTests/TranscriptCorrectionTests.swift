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
            .init(id: 0, text: "ёлка и Avia Calls"),
            .init(id: 1, text: "вторая ёлка"),
        ])
        let corrected = try document.applying([
            .init(id: 0, original: "ёлка", replacement: "Ёлка", termIndex: 1),
            .init(id: 0, original: "Avia Calls", replacement: "AviaCalls", termIndex: 0),
        ], glossary: correctionGlossary())
        #expect(corrected == "# Встреча\n\nУчастники: Алёна\n\n[00:00:01] Алёна: Ёлка и AviaCalls\n[00:00:02] (экран) screens/00-00-02.jpg\n[00:00:03] Bob: вторая ёлка\n")
    }

    @Test func rejectsUnsafeOrAmbiguousChanges() {
        let document = TranscriptCorrection.Document(source)
        let glossary = correctionGlossary()
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 0, original: "нет", replacement: "да", termIndex: 0)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 0, original: "ёлка", replacement: "ёлка", termIndex: 1)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 0, original: "ёлка\n", replacement: "Ёлка", termIndex: 1)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 99, original: "ёлка", replacement: "Ёлка", termIndex: 1)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 0, original: "ёлка", replacement: "Ёлка", termIndex: 9)], glossary: glossary)
        }
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([
                .init(id: 0, original: "ёлка и", replacement: "Ёлка и", termIndex: 1),
                .init(id: 0, original: "и Avia", replacement: "и avia", termIndex: 0),
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
        #expect(document.segments == [.init(id: 0, text: "ёлка")])
        let corrected = try document.applying([.init(id: 0, original: "ёлка", replacement: "Ёлка", termIndex: 1)], glossary: correctionGlossary())
        #expect(Array(corrected.utf8) == Array(source.replacingOccurrences(of: "ёлка", with: "Ёлка").utf8))
    }

    @Test func legacySpeakerWithColonCannotBeSentOrCorrected() {
        let source = "[00:00:01] Команда: Арбита: Готово.\n"
        let document = TranscriptCorrection.Document(source)
        #expect(document.segments.map(\.text) == ["Готово."])
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 0, original: "Арбита", replacement: "Орбита", termIndex: 0)], glossary: correctionGlossary())
        }
    }

    @Test(arguments: ["Команда: Арбита", "(экран) Иван", "(экран)"])
    func rendererMapSeparatesColonsInNamesAndSpeech(speaker: String) throws {
        let rendered = TranscriptRenderer.document(title: "Встреча", start: Date(timeIntervalSince1970: 0), participants: [speaker],
                                                    utterances: [.init(start: 1, speaker: speaker, text: "Арбита: продукт готов.")],
                                                    screenshots: [.init(time: 2, path: "screens/test.jpg")])
        let document = TranscriptCorrection.Document(rendered.text, speakers: rendered.speakers)
        #expect(document.segments.map(\.text) == ["Арбита: продукт готов."])
        let glossary = Glossary(entries: [.init(term: "Орбита", description: "")])
        let corrected = try document.applying([.init(id: 0, original: "Арбита", replacement: "Орбита", termIndex: 0)], glossary: glossary)
        #expect(corrected.contains("[00:00:01] \(speaker): Орбита: продукт готов."))
        #expect(corrected.contains("[00:00:02] (экран) screens/test.jpg"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-speakers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TranscriptCorrection.saveSpeakers(rendered.speakers, source: rendered.text, in: dir)
        #expect(TranscriptCorrection.loadSpeakers(source: rendered.text, in: dir) == rendered.speakers)
        #expect(TranscriptCorrection.loadSpeakers(source: rendered.text + "changed", in: dir).isEmpty)
    }

    @Test func replacementLengthBoundariesAndDuplicateChanges() throws {
        let source = "[00:00:01] A: " + String(repeating: "а", count: 201) + "\n"
        let document = TranscriptCorrection.Document(source)
        let original = String(repeating: "а", count: 200)
        let invalid = TranscriptCorrection.Change(id: 0, original: String(repeating: "а", count: 201), replacement: "Ёлка", termIndex: 1)
        #expect(throws: TranscriptCorrection.ValidationError.self) { try document.applying([invalid], glossary: correctionGlossary()) }
        let bounded = TranscriptCorrection.Document("[00:00:01] A: " + original + "\n")
        let change = TranscriptCorrection.Change(id: 0, original: original, replacement: String(repeating: "б", count: 200), termIndex: 1)
        #expect(try bounded.applying([change], glossary: correctionGlossary()).contains(String(repeating: "б", count: 200)))
        #expect(throws: TranscriptCorrection.ValidationError.self) { try bounded.applying([change, change], glossary: correctionGlossary()) }
        let tooLong = TranscriptCorrection.Change(id: 0, original: original, replacement: String(repeating: "б", count: 201), termIndex: 1)
        #expect(throws: TranscriptCorrection.ValidationError.self) { try bounded.applying([tooLong], glossary: correctionGlossary()) }
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"])
    func rejectsEveryLineBreakInReplacement(_ newline: String) {
        let document = TranscriptCorrection.Document(source)
        #expect(throws: TranscriptCorrection.ValidationError.self) {
            try document.applying([.init(id: 0, original: "ёлка", replacement: "Ёлка" + newline + "лишняя строка", termIndex: 1)], glossary: correctionGlossary())
        }
    }
}

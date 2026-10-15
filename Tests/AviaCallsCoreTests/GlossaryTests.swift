import Testing
@testable import AviaCallsCore

@Suite struct GlossaryTests {
    @Test func parsesQuotedBOMAndCRLF() throws {
        let glossary = try Glossary(csv: "\u{FEFF}term,description\r\n\"Вася, Пупкин\",\"первая строка\nвторая \"\"цитата\"\"\"\r\nЁлка,\r\n\r\n")
        #expect(glossary.entries == [
            Glossary.Entry(term: "Вася, Пупкин", description: "первая строка\nвторая \"цитата\""),
            Glossary.Entry(term: "Ёлка", description: ""),
        ])
    }

    @Test func rejectsInvalidStructureAndDuplicates() {
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: "term\nслово\n") }
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: "term,description\nодин,два,три\n") }
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: "term,description\n,описание\n") }
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: "term,description\n\"две\nстроки\",описание\n") }
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: "term,description\nЁлка,a\nёлка,b\n") }
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: "") }
    }

    @Test func enforcesEntryAndUTF8ByteLimits() throws {
        let thousand = "term,description\n" + (1...1000).map { "Термин \($0),\n" }.joined()
        #expect(try Glossary(csv: thousand).entries.count == 1000)
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: thousand + "Ещё один,\n") }
        let prefix = "term,description\nТермин,"
        let atLimit = prefix + String(repeating: "a", count: 128 * 1024 - prefix.utf8.count)
        #expect(try Glossary(csv: atLimit).entries.count == 1)
        #expect(throws: Glossary.ValidationError.self) { try Glossary(csv: atLimit + "a") }
    }
}

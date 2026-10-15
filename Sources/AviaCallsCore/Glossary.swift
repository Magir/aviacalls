import Foundation

public struct Glossary: Sendable, Equatable {
    public struct Entry: Codable, Equatable, Sendable {
        public let term: String
        public let description: String

        public init(term: String, description: String) {
            self.term = term
            self.description = description
        }
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case tooLarge
        case malformed(line: Int)
        case header(line: Int)
        case columns(line: Int)
        case emptyTerm(line: Int)
        case invalidTerm(line: Int)
        case duplicateTerm(line: Int)
        case tooManyEntries

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "Словарь превышает допустимый размер."
            case .malformed(let line): return "Некорректный CSV в строке \(line)."
            case .header(let line): return "В строке \(line) ожидается заголовок term,description."
            case .columns(let line): return "В строке \(line) должно быть две колонки."
            case .emptyTerm(let line): return "В строке \(line) пустой термин."
            case .invalidTerm(let line): return "В строке \(line) термин не должен содержать перенос строки."
            case .duplicateTerm(let line): return "В строке \(line) повторяется термин."
            case .tooManyEntries: return "В словаре слишком много терминов."
            }
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(csv: String) throws {
        guard csv.utf8.count <= 128 * 1024 else { throw ValidationError.tooLarge }
        let rows = try CSV.parse(csv)
        guard let header = rows.first else { throw ValidationError.header(line: 1) }
        guard header.values == ["term", "description"] else { throw ValidationError.header(line: header.line) }

        var terms = Set<String>()
        var parsed: [Entry] = []
        for row in rows.dropFirst() {
            guard row.values.count == 2 else { throw ValidationError.columns(line: row.line) }
            let term = row.values[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { throw ValidationError.emptyTerm(line: row.line) }
            guard !term.contains(where: \.isNewline) else { throw ValidationError.invalidTerm(line: row.line) }
            guard terms.insert(term.lowercased()).inserted else { throw ValidationError.duplicateTerm(line: row.line) }
            parsed.append(Entry(term: term, description: row.values[1]))
            guard parsed.count <= 1_000 else { throw ValidationError.tooManyEntries }
        }
        entries = parsed
    }
}

private enum CSV {
    struct Row {
        let line: Int
        let values: [String]
    }

    static func parse(_ source: String) throws -> [Row] {
        var input = source.replacingOccurrences(of: "\r\n", with: "\n")
        if input.unicodeScalars.first?.value == 0xFEFF { input.removeFirst() }
        var rows: [Row] = []
        var values: [String] = []
        var field = ""
        var line = 1
        var rowLine = 1
        var quoted = false
        var afterQuote = false
        var index = input.startIndex

        func appendRow() {
            values.append(field)
            if !(values.count == 1 && values[0].isEmpty) { rows.append(Row(line: rowLine, values: values)) }
            values = []
            field = ""
            afterQuote = false
        }

        while index < input.endIndex {
            let character = input[index]
            if quoted {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                    } else {
                        quoted = false
                        afterQuote = true
                        index = next
                    }
                } else {
                    if character == "\r" { throw Glossary.ValidationError.malformed(line: line) }
                    field.append(character)
                    if character == "\n" { line += 1 }
                    index = input.index(after: index)
                }
                continue
            }

            if afterQuote && character != "," && character != "\n" {
                throw Glossary.ValidationError.malformed(line: line)
            }
            switch character {
            case "\"":
                guard field.isEmpty && !afterQuote else { throw Glossary.ValidationError.malformed(line: line) }
                quoted = true
            case ",":
                values.append(field)
                field = ""
                afterQuote = false
            case "\n":
                appendRow()
                line += 1
                rowLine = line
            default:
                guard character != "\r" else { throw Glossary.ValidationError.malformed(line: line) }
                field.append(character)
            }
            index = input.index(after: index)
        }
        guard !quoted else { throw Glossary.ValidationError.malformed(line: line) }
        if !values.isEmpty || !field.isEmpty || afterQuote { appendRow() }
        return rows
    }
}

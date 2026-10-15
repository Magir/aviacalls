import CryptoKit
import Foundation

public enum TranscriptCorrection {
    public struct Segment: Codable, Equatable, Sendable {
        public let id: Int
        public let text: String

        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct Change: Codable, Equatable, Sendable {
        public let id: Int
        public let original: String
        public let replacement: String
        public let termIndex: Int

        public init(id: Int, original: String, replacement: String, termIndex: Int) {
            self.id = id
            self.original = original
            self.replacement = replacement
            self.termIndex = termIndex
        }
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidChange
        case unknownSegment
        case unknownTerm
        case ambiguousChange
        case overlappingChanges

        public var errorDescription: String? {
            switch self {
            case .invalidChange: return "Некорректное исправление."
            case .unknownSegment: return "Исправление ссылается на неизвестную реплику."
            case .unknownTerm: return "Исправление ссылается на неизвестный термин."
            case .ambiguousChange: return "Текст для исправления должен встретиться ровно один раз."
            case .overlappingChanges: return "Исправления пересекаются."
            }
        }
    }

    public struct Document: Sendable {
        public let source: String
        public let segments: [Segment]
        private let ranges: [Range<String.Index>]

        public init(_ source: String, speakers: [Int: String] = [:]) {
            self.source = source
            var ranges: [Range<String.Index>] = []
            for line in Self.lines(in: source) {
                guard let speech = Self.speech(in: source, line: line, speaker: speakers[line.id]) else { continue }
                var start = speech.lowerBound
                while start < speech.upperBound {
                    var end = source.index(start, offsetBy: 8_000, limitedBy: speech.upperBound) ?? speech.upperBound
                    // По возможности не разрываем слово; привязка к исходным диапазонам сохраняется.
                    if end < speech.upperBound, let space = source[start..<end].lastIndex(where: \.isWhitespace) {
                        end = source.index(after: space)
                    }
                    ranges.append(start..<end)
                    start = end
                }
            }
            self.ranges = ranges
            segments = ranges.enumerated().map { Segment(id: $0.offset, text: String(source[$0.element])) }
        }

        public func applying(_ changes: [Change], glossary: Glossary) throws -> String {
            let replacements = try validatedReplacements(changes, glossary: glossary)
            guard !replacements.isEmpty else { return source }
            var corrected = ""
            corrected.reserveCapacity(source.utf8.count)
            var start = source.startIndex
            for (range, replacement) in replacements {
                corrected.append(contentsOf: source[start..<range.lowerBound])
                corrected.append(replacement)
                start = range.upperBound
            }
            corrected.append(contentsOf: source[start...])
            return corrected
        }

        /// Проверка порции не строит и не выбрасывает копию всей расшифровки.
        public func validate(_ changes: [Change], glossary: Glossary) throws {
            _ = try validatedReplacements(changes, glossary: glossary)
        }

        private func validatedReplacements(_ changes: [Change], glossary: Glossary) throws -> [(Range<String.Index>, String)] {
            var replacements: [(Range<String.Index>, String)] = []

            for change in changes {
                guard change.termIndex >= 0 && change.termIndex < glossary.entries.count else {
                    throw ValidationError.unknownTerm
                }
                guard !change.original.isEmpty, !change.replacement.isEmpty,
                      change.original.count <= 200, change.replacement.count <= 200,
                      !change.original.contains(where: \.isNewline),
                      !change.replacement.contains(where: \.isNewline),
                      change.original != change.replacement else {
                    throw ValidationError.invalidChange
                }
                guard ranges.indices.contains(change.id) else { throw ValidationError.unknownSegment }
                let text = segments[change.id].text
                guard let match = text.uniqueRange(of: change.original) else { throw ValidationError.ambiguousChange }
                let offset = text.distance(from: text.startIndex, to: match.lowerBound)
                let start = source.index(ranges[change.id].lowerBound, offsetBy: offset)
                let end = source.index(start, offsetBy: change.original.count)
                replacements.append((start..<end, change.replacement))
            }

            let ordered = replacements.sorted { $0.0.lowerBound < $1.0.lowerBound }
            for pair in zip(ordered, ordered.dropFirst()) where pair.0.0.overlaps(pair.1.0) {
                throw ValidationError.overlappingChanges
            }
            return ordered
        }

        private struct Line {
            let id: Int
            let content: Range<String.Index>
        }

        private static func lines(in source: String) -> [Line] {
            var lines: [Line] = []
            var start = source.startIndex
            var id = 0
            while start < source.endIndex {
                // CRLF — один Character в Swift; сохраняем исходные окончания строк без нормализации.
                let end = source[start...].firstIndex(where: \.isNewline) ?? source.endIndex
                lines.append(Line(id: id, content: start..<end))
                id += 1
                guard end < source.endIndex else { break }
                start = source.index(after: end)
            }
            return lines
        }

        private static func speech(in source: String, line: Line, speaker: String?) -> Range<String.Index>? {
            let content = source[line.content]
            guard content.count >= 12, content.first == "[" else { return nil }
            let chars = Array(content.prefix(11))
            guard chars[3] == ":", chars[6] == ":", chars[9] == "]", chars[10] == " ",
                  chars[1...2].allSatisfy(\.isNumber), chars[4...5].allSatisfy(\.isNumber), chars[7...8].allSatisfy(\.isNumber) else { return nil }
            let start = source.index(content.startIndex, offsetBy: 11)
            let rest = source[start..<content.endIndex]
            let textStart: String.Index
            if let speaker, rest.hasPrefix(speaker + ": ") {
                textStart = source.index(start, offsetBy: speaker.count + 2)
            } else {
                guard !rest.hasPrefix("(экран) "), !rest.hasPrefix("(экран): ") else { return nil }
                // В старом Markdown нет экранирования имён. Последний разделитель заведомо
                // не раньше границы речи: безопаснее оставить часть речи без исправлений, чем менять имя.
                guard let delimiter = rest.range(of: ": ", options: .backwards) else { return nil }
                textStart = delimiter.upperBound
            }
            return textStart < content.endIndex ? textStart..<content.endIndex : nil
        }
    }

    /// Разметка строится из Utterance до сериализации в неоднозначный Markdown и привязана к его содержимому.
    public static func saveSpeakers(_ speakers: [Int: String], source: String, in dir: URL) throws {
        let data = try JSONEncoder().encode(SpeakerMap(sourceHash: hash(source), speakers: speakers))
        try data.write(to: dir.appendingPathComponent("transcript.speakers.json"), options: .atomic)
    }

    public static func loadSpeakers(source: String, in dir: URL) -> [Int: String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.speakers.json")),
              let map = try? JSONDecoder().decode(SpeakerMap.self, from: data),
              map.sourceHash == hash(source) else { return [:] }
        return map.speakers
    }

    private struct SpeakerMap: Codable {
        let sourceHash: String
        let speakers: [Int: String]
    }

    public static func save(_ corrected: String, source: String, in dir: URL) throws {
        let marker = "<!-- AviaCalls source-sha256: \(hash(source)) -->\n"
        try (marker + corrected).write(to: dir.appendingPathComponent("transcript.corrected.md"), atomically: true, encoding: .utf8)
    }

    public static func currentURL(in dir: URL) -> URL? {
        let originalURL = dir.appendingPathComponent("transcript.md")
        let correctedURL = dir.appendingPathComponent("transcript.corrected.md")
        // Сначала читаем только короткий маркер: без исправленной версии исходник вообще не нужен.
        guard let handle = try? FileHandle(forReadingFrom: correctedURL) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 128),
              let newline = header.firstIndex(of: 10),
              let firstLine = String(data: header[..<newline], encoding: .utf8),
              firstLine.hasPrefix("<!-- AviaCalls source-sha256: "), firstLine.hasSuffix(" -->"),
              let source = try? String(contentsOf: originalURL, encoding: .utf8) else { return nil }
        return firstLine == "<!-- AviaCalls source-sha256: \(hash(source)) -->" ? correctedURL : nil
    }

    private static func hash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func uniqueRange(of needle: String) -> Range<Index>? {
        guard let first = range(of: needle) else { return nil }
        let next = index(after: first.lowerBound)
        // Считаем и пересекающиеся совпадения; после второго дальнейший поиск не нужен.
        guard range(of: needle, range: next..<endIndex) == nil else { return nil }
        return first
    }
}

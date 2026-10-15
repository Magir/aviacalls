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

        public init(_ source: String) {
            self.source = source
            segments = Self.lines(in: source).compactMap { line in
                Self.segment(id: line.id, content: String(source[line.content]))
            }
        }

        public func applying(_ changes: [Change], glossary: Glossary) throws -> String {
            let lines = Self.lines(in: source)
            let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
            var replacements: [(Range<String.Index>, String)] = []

            for change in changes {
                guard change.termIndex >= 0 && change.termIndex < glossary.entries.count else {
                    throw ValidationError.unknownTerm
                }
                guard !change.original.isEmpty, !change.replacement.isEmpty,
                      change.original.count <= 200, change.replacement.count <= 200,
                      !change.original.contains(where: { $0 == "\n" || $0 == "\r" }),
                      !change.replacement.contains(where: { $0 == "\n" || $0 == "\r" }),
                      change.original != change.replacement else {
                    throw ValidationError.invalidChange
                }
                guard let text = segmentsByID[change.id], let line = lines.first(where: { $0.id == change.id }) else {
                    throw ValidationError.unknownSegment
                }
                let matches = text.ranges(of: change.original)
                guard matches.count == 1, let match = matches.first else { throw ValidationError.ambiguousChange }
                let offset = text.distance(from: text.startIndex, to: match.lowerBound)
                let lineText = source[line.content]
                let speakerStart = lineText.index(lineText.startIndex, offsetBy: 11)
                guard let delimiter = lineText.range(of: ": ", range: speakerStart..<lineText.endIndex) else {
                    throw ValidationError.unknownSegment
                }
                let start = lineText.index(delimiter.upperBound, offsetBy: offset)
                let end = source.index(start, offsetBy: change.original.count)
                replacements.append((start..<end, change.replacement))
            }

            let ordered = replacements.sorted { $0.0.lowerBound < $1.0.lowerBound }
            for pair in zip(ordered, ordered.dropFirst()) where pair.0.0.overlaps(pair.1.0) {
                throw ValidationError.overlappingChanges
            }
            var corrected = source
            for replacement in ordered.reversed() {
                corrected.replaceSubrange(replacement.0, with: replacement.1)
            }
            return corrected
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
                let end = source[start...].firstIndex(of: "\n") ?? source.endIndex
                let contentEnd = end > start && source[source.index(before: end)] == "\r" ? source.index(before: end) : end
                lines.append(Line(id: id, content: start..<contentEnd))
                id += 1
                guard end < source.endIndex else { break }
                start = source.index(after: end)
            }
            return lines
        }

        private static func segment(id: Int, content: String) -> Segment? {
            guard content.count >= 12, content.first == "[" else { return nil }
            let chars = Array(content)
            guard chars[3] == ":", chars[6] == ":", chars[9] == "]", chars[10] == " ",
                  chars[1...2].allSatisfy(\.isNumber), chars[4...5].allSatisfy(\.isNumber), chars[7...8].allSatisfy(\.isNumber),
                  let speakerEnd = content.range(of: ": ", range: content.index(content.startIndex, offsetBy: 11)..<content.endIndex) else { return nil }
            let speaker = content[content.index(content.startIndex, offsetBy: 11)..<speakerEnd.lowerBound]
            let textStart = speakerEnd.upperBound
            guard speaker != "(экран)", textStart < content.endIndex else { return nil }
            return Segment(id: id, text: String(content[textStart...]))
        }
    }

    public static func save(_ corrected: String, source: String, in dir: URL) throws {
        let marker = "<!-- AviaCalls source-sha256: \(hash(source)) -->\n"
        try (marker + corrected).write(to: dir.appendingPathComponent("transcript.corrected.md"), atomically: true, encoding: .utf8)
    }

    public static func currentURL(in dir: URL) -> URL? {
        let originalURL = dir.appendingPathComponent("transcript.md")
        let correctedURL = dir.appendingPathComponent("transcript.corrected.md")
        guard let source = try? String(contentsOf: originalURL, encoding: .utf8),
              let corrected = try? String(contentsOf: correctedURL, encoding: .utf8),
              let firstLine = corrected.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        return firstLine == "<!-- AviaCalls source-sha256: \(hash(source)) -->" ? correctedURL : nil
    }

    private static func hash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<Index>] {
        var ranges: [Range<Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex, let range = range(of: needle, range: searchStart..<endIndex) {
            ranges.append(range)
            searchStart = index(after: range.lowerBound)
        }
        return ranges
    }
}

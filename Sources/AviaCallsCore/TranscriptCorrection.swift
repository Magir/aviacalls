import CryptoKit
import Foundation

public enum TranscriptCorrection {
    public struct Segment: Codable, Equatable, Sendable {
        public let id: Int
        public let text: String
        public let continuesPrevious: Bool
        public let continuesNext: Bool

        public init(id: Int, text: String, continuesPrevious: Bool = false, continuesNext: Bool = false) {
            self.id = id
            self.text = text
            self.continuesPrevious = continuesPrevious
            self.continuesNext = continuesNext
        }
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case unknownSegment, duplicateSegment, incompleteSegments, emptySegment, invalidText, segmentTooLong, documentTooLong

        public var errorDescription: String? {
            switch self {
            case .unknownSegment: return "Исправление ссылается на неизвестную реплику."
            case .duplicateSegment: return "Ответ содержит одну и ту же реплику больше одного раза."
            case .incompleteSegments: return "Ответ не содержит все реплики расшифровки."
            case .emptySegment: return "Исправленная реплика не может быть пустой."
            case .invalidText: return "Исправленная реплика содержит недопустимый перенос или управляющий символ."
            case .segmentTooLong: return "Исправленная реплика слишком длинная."
            case .documentTooLong: return "Исправленная расшифровка слишком длинная."
            }
        }
    }

    public static func validate(_ edited: [Segment], for original: [Segment]) throws {
        var originalByID: [Int: Segment] = [:]
        for segment in original { originalByID[segment.id] = segment }
        var receivedIDs: Set<Int> = []
        var totalLength = 0

        for segment in edited {
            guard let originalSegment = originalByID[segment.id] else { throw ValidationError.unknownSegment }
            guard receivedIDs.insert(segment.id).inserted else { throw ValidationError.duplicateSegment }
            guard !segment.text.contains(where: \.isNewline),
                  !segment.text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw ValidationError.invalidText }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.emptySegment }
            guard segment.text.count <= originalSegment.text.count * 5 / 4 + 64 else { throw ValidationError.segmentTooLong }
            totalLength += segment.text.count
        }

        guard receivedIDs == Set(originalByID.keys) else { throw ValidationError.incompleteSegments }
        let originalLength = original.reduce(0) { $0 + $1.text.count }
        guard totalLength <= originalLength * 5 / 4 + 256 else { throw ValidationError.documentTooLong }
    }

    public struct Document: Sendable {
        public let source: String
        public let segments: [Segment]
        private let ranges: [Range<String.Index>]

        public init(_ source: String, speakers: [Int: String] = [:]) {
            self.source = source
            var ranges: [Range<String.Index>] = []
            var segments: [Segment] = []
            for line in Self.lines(in: source) {
                guard let speech = Self.speech(in: source, line: line, speaker: speakers[line.id]) else { continue }
                let chunks = Self.chunks(in: source, speech: speech)
                for (index, range) in chunks.enumerated() {
                    let id = segments.count
                    ranges.append(range)
                    segments.append(Segment(id: id, text: String(source[range]), continuesPrevious: index > 0, continuesNext: index + 1 < chunks.count))
                }
            }
            self.ranges = ranges
            self.segments = segments
        }

        public func applying(_ edited: [Segment]) throws -> String {
            try TranscriptCorrection.validate(edited, for: segments)
            let editedByID = Dictionary(uniqueKeysWithValues: edited.map { ($0.id, $0.text) })
            var corrected = ""
            corrected.reserveCapacity(source.utf8.count)
            var start = source.startIndex
            for (index, range) in ranges.enumerated() {
                corrected.append(contentsOf: source[start..<range.lowerBound])
                corrected.append(editedByID[segments[index].id]!)
                start = range.upperBound
            }
            corrected.append(contentsOf: source[start...])
            return corrected
        }

        private static func chunks(in source: String, speech: Range<String.Index>) -> [Range<String.Index>] {
            var chunks: [Range<String.Index>] = []
            var start = speech.lowerBound
            while start < speech.upperBound {
                while start < speech.upperBound, source[start].isWhitespace { start = source.index(after: start) }
                guard start < speech.upperBound else { break }

                var limit = start
                var characterCount = 0
                var utf8Count = 0
                while limit < speech.upperBound {
                    let character = source[limit]
                    guard characterCount + 1 <= 4_000, utf8Count + character.utf8.count <= 8_000 else { break }
                    characterCount += 1
                    utf8Count += character.utf8.count
                    limit = source.index(after: limit)
                }

                if limit == speech.upperBound {
                    var end = limit
                    while end > start, source[source.index(before: end)].isWhitespace { end = source.index(before: end) }
                    if end > start { chunks.append(start..<end) }
                    break
                }

                let window = source[start..<limit]
                if let whitespace = window.lastIndex(where: \.isWhitespace) {
                    var sentenceWhitespace: String.Index?
                    for index in window.indices where source[index].isWhitespace {
                        let previous = source.index(before: index)
                        if ".?!…".contains(source[previous]) { sentenceWhitespace = index }
                    }
                    let end = sentenceWhitespace ?? whitespace
                    chunks.append(start..<end)
                    start = end
                    continue
                }

                var end = limit
                while end < speech.upperBound, !source[end].isWhitespace { end = source.index(after: end) }
                chunks.append(start..<end)
                start = end
            }
            return chunks
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

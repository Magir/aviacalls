import Foundation

/// Встреча в списке: всё, что нужно показать, не открывая транскрипт.
public struct MeetingSummary: Equatable, Identifiable, Sendable {
    public var dir: URL
    public var title: String
    public var start: Date
    public var end: Date?
    public var participants: [String]
    public var hasTranscript: Bool
    public var hasAudio: Bool
    public var postprocessingCost: PostprocessingCost? = nil
    public var id: URL { dir }
}

public struct TranscriptLine: Equatable, Identifiable, Sendable {
    public var id: Int
    public var time: String
    public var speaker: String
    public var text: String
}

/// Читает папку встреч с диска.
public enum MeetingLibrary {
    public static func load(root: URL) -> [MeetingSummary] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap(summary).sorted { $0.start > $1.start }
    }

    static func summary(_ dir: URL) -> MeetingSummary? {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
        let hasAudio = ["zoom.caf", "zoom.m4a", "mic.caf", "mic.m4a"].contains(where: has)
        let hasTranscript = has("transcript.md")
        if let info = try? MeetingStore(existing: dir).loadInfo() {
            return MeetingSummary(dir: dir, title: info.title ?? "Встреча", start: info.start, end: info.end,
                                  participants: info.participants, hasTranscript: hasTranscript, hasAudio: hasAudio, postprocessingCost: info.postprocessingCost)
        }
        // meeting.json нет: приложение убили до первого сохранения. Дату и название берём из имени папки.
        let name = dir.lastPathComponent
        guard hasAudio, let start = MeetingStore.stamp.date(from: String(name.prefix(16))) else { return nil }
        let title = name.dropFirst(16).trimmingCharacters(in: .whitespaces)
        return MeetingSummary(dir: dir, title: title.isEmpty ? "Встреча" : title, start: start, end: nil,
                              participants: [], hasTranscript: hasTranscript, hasAudio: hasAudio, postprocessingCost: nil)
    }

    public struct SearchHit: Equatable, Sendable {
        public var meeting: MeetingSummary
        public var lines: [TranscriptLine]
    }

    /// Неизменяемый снимок расшифровок для поиска без повторного чтения с диска.
    public struct SearchSnapshot: Sendable {
        fileprivate struct FileFingerprint: Equatable, Sendable {
            let path: String
            let modificationDate: Date?
            let size: Int?
            let identifier: String?
        }

        fileprivate struct LibraryFingerprint: Equatable, Sendable {
            let rootContents: [FileFingerprint]
            let meetingFiles: [FileFingerprint]
        }

        fileprivate struct IndexedLine: Sendable {
            let line: TranscriptLine
            let searchable: String
        }

        fileprivate struct IndexedMeeting: Sendable {
            let meeting: MeetingSummary
            let header: String
            let lines: [IndexedLine]
        }

        private let index: [IndexedMeeting]
        private let fingerprint: LibraryFingerprint
        public let meetings: [MeetingSummary]

        fileprivate init(_ entries: [IndexedMeeting], fingerprint: LibraryFingerprint) {
            index = entries
            meetings = entries.map(\.meeting)
            self.fingerprint = fingerprint
        }

        /// Ищет в заранее разобранном снимке. Снимок надо пересоздать после изменения библиотеки.
        public func search(query: String) -> [SearchHit] {
            let q = MeetingLibrary.fold(query)
            guard !q.isEmpty else { return [] }
            return index.compactMap { entry in
                let hits = entry.lines.compactMap { $0.searchable.contains(q) ? $0.line : nil }
                return hits.isEmpty && !entry.header.contains(q) ? nil : SearchHit(meeting: entry.meeting, lines: hits)
            }
        }

        /// То же, что `search(query:)`, но отдаёт выполнение отменённой задаче между встречами.
        public func searchCancellable(query: String) async -> [SearchHit] {
            let q = MeetingLibrary.fold(query)
            guard !q.isEmpty else { return [] }
            var results: [SearchHit] = []
            for (offset, entry) in index.enumerated() {
                guard !Task.isCancelled else { return [] }
                let hits = entry.lines.compactMap { $0.searchable.contains(q) ? $0.line : nil }
                if !hits.isEmpty || entry.header.contains(q) {
                    results.append(SearchHit(meeting: entry.meeting, lines: hits))
                }
                if offset.isMultiple(of: 16) { await Task.yield() }
            }
            return results
        }

        /// Проверяет метаданные библиотеки без чтения расшифровок.
        public func isCurrent(root: URL) -> Bool {
            fingerprint == MeetingLibrary.fingerprint(root: root)
        }
    }

    /// Читает текущие расшифровки и готовит снимок для последующих поисков.
    public static func searchSnapshot(root: URL) -> SearchSnapshot {
        let fingerprint = fingerprint(root: root)
        return SearchSnapshot(load(root: root).map(indexedMeeting), fingerprint: fingerprint)
    }

    /// Читает список и строит снимок в фоновой задаче, если старый снимок устарел.
    public static func searchSnapshotCancellable(root: URL) async -> SearchSnapshot? {
        let fingerprint = fingerprint(root: root)
        let meetings = load(root: root)
        var entries: [SearchSnapshot.IndexedMeeting] = []
        entries.reserveCapacity(meetings.count)
        for (offset, meeting) in meetings.enumerated() {
            guard !Task.isCancelled else { return nil }
            entries.append(indexedMeeting(meeting))
            if offset.isMultiple(of: 16) { await Task.yield() }
        }
        return SearchSnapshot(entries, fingerprint: fingerprint)
    }

    /// Полнотекстовый поиск по всем расшифровкам. Каждый вызов читает актуальное состояние диска.
    public static func search(root: URL, query: String) -> [SearchHit] {
        guard !fold(query).isEmpty else { return [] }
        return searchSnapshot(root: root).search(query: query)
    }

    private static func indexedMeeting(_ meeting: MeetingSummary) -> SearchSnapshot.IndexedMeeting {
        let url = TranscriptCorrection.currentURL(in: meeting.dir) ?? meeting.dir.appendingPathComponent("transcript.md")
        let transcriptLines = lines((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        return SearchSnapshot.IndexedMeeting(
            meeting: meeting,
            header: fold(meeting.title + "\n" + meeting.participants.joined(separator: "\n")),
            lines: transcriptLines.map { SearchSnapshot.IndexedLine(line: $0, searchable: fold($0.speaker + "\n" + $0.text)) }
        )
    }

    private static func fingerprint(root: URL) -> SearchSnapshot.LibraryFingerprint {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let rootContents = contents
            .map(fileFingerprint)
            .sorted { $0.path < $1.path }
        let meetingFiles = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.flatMap { meeting in
            ["meeting.json", "transcript.md", "transcript.corrected.md"].map {
                fileFingerprint(meeting.appendingPathComponent($0))
            }
        }
        return SearchSnapshot.LibraryFingerprint(rootContents: rootContents, meetingFiles: meetingFiles)
    }

    private static func fileFingerprint(_ url: URL) -> SearchSnapshot.FileFingerprint {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey])
        return SearchSnapshot.FileFingerprint(path: url.path, modificationDate: values?.contentModificationDate,
                                              size: values?.fileSize, identifier: (values?.fileResourceIdentifier as? NSNumber)?.stringValue)
    }

    /// Строки одной расшифровки, где встречается запрос — в тексте или в имени говорящего.
    public static func filter(_ lines: [TranscriptLine], query: String) -> [TranscriptLine] {
        let q = fold(query)
        guard !q.isEmpty else { return lines }
        return lines.filter { fold($0.text).contains(q) || fold($0.speaker).contains(q) }
    }

    /// Путь, который можно вставить в терминал или команду для ИИ: пробелы и спецсимволы экранированы.
    public static func shellPath(_ path: String) -> String {
        let special: Set<Character> = [" ", "(", ")", "'", "\"", "&", ";", "$", "`", "\\", "!", "*", "?", "[", "]", "<", ">", "|"]
        return path.reduce(into: "") { out, ch in
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
    }

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е").trimmingCharacters(in: .whitespaces)
    }

    /// «Ann, Bob, Cid и ещё 2» — участники одной строкой для списка.
    public static func participantsLine(_ names: [String], limit: Int = 3) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) и ещё \(names.count - limit)" : shown
    }

    /// Строки вида `[00:12:43] Имя: текст` из transcript.md; шапку и всё остальное пропускает.
    public static func lines(_ transcript: String) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        for line in transcript.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let colon = line.range(of: ": ", range: close..<line.endIndex) else { continue }
            let speakerStart = line.index(close, offsetBy: 2, limitedBy: colon.lowerBound) ?? colon.lowerBound
            out.append(TranscriptLine(id: out.count, time: String(line[line.index(after: line.startIndex)..<close]),
                                      speaker: String(line[speakerStart..<colon.lowerBound]), text: String(line[colon.upperBound...])))
        }
        return out
    }
}

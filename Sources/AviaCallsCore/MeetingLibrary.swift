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
                                  participants: info.participants, hasTranscript: hasTranscript, hasAudio: hasAudio)
        }
        // meeting.json нет: приложение убили до первого сохранения. Дату и название берём из имени папки.
        let name = dir.lastPathComponent
        guard hasAudio, let start = MeetingStore.stamp.date(from: String(name.prefix(16))) else { return nil }
        let title = name.dropFirst(16).trimmingCharacters(in: .whitespaces)
        return MeetingSummary(dir: dir, title: title.isEmpty ? "Встреча" : title, start: start, end: nil,
                              participants: [], hasTranscript: hasTranscript, hasAudio: hasAudio)
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

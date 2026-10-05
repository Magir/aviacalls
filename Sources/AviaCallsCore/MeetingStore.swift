import Foundation

public struct MeetingInfo: Codable, Equatable, Sendable {
    public var title: String?
    public var start: Date
    public var end: Date?
    public var participants: [String]
    public var myName: String?
    public var namesRead: Bool      // false — Zoom не отдал участников, транскрипт без имён
    public var micOffset: Double    // секунды от начала записи до первого звука дорожки
    public var zoomOffset: Double

    public init(title: String?, start: Date, end: Date?, participants: [String], myName: String?,
                namesRead: Bool, micOffset: Double, zoomOffset: Double) {
        self.title = title; self.start = start; self.end = end; self.participants = participants
        self.myName = myName; self.namesRead = namesRead; self.micOffset = micOffset; self.zoomOffset = zoomOffset
    }
}

public struct TrackWords: Codable, Equatable, Sendable {
    public var mic: [Word]
    public var zoom: [Word]
    public init(mic: [Word], zoom: [Word]) { self.mic = mic; self.zoom = zoom }
}

/// Папка одной встречи на диске.
public final class MeetingStore {
    public private(set) var dir: URL
    private let fm = FileManager.default

    public init(root: URL, start: Date) throws {
        dir = Self.free(root.appendingPathComponent(Self.stamp.string(from: start)))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public init(existing dir: URL) { self.dir = dir }

    /// Формат даты в имени папки встречи.
    public static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    public func append(_ events: [TimedEvent]) throws {
        guard !events.isEmpty else { return }
        let url = dir.appendingPathComponent("timeline.jsonl")
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for e in events { try handle.write(contentsOf: try JSONEncoder().encode(e) + Data("\n".utf8)) }
    }

    public func loadTimeline() throws -> [TimedEvent] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("timeline.jsonl"), encoding: .utf8) else { return [] }
        // оборванную последнюю строку (приложение убили посреди записи) пропускаем
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(TimedEvent.self, from: Data($0.utf8)) }
    }

    public func save(info: MeetingInfo) throws { try write(info, "meeting.json") }
    public func loadInfo() throws -> MeetingInfo { try read("meeting.json") }
    public func save(words: TrackWords) throws { try write(words, "segments.json") }
    public func loadWords() -> TrackWords? { try? read("segments.json") }
    public func save(screenshots: [Screenshot]) throws { try write(screenshots, "screenshots.json") }
    public func loadScreenshots() -> [Screenshot] { (try? read("screenshots.json")) ?? [] }
    public func save(transcript: String) throws {
        try transcript.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    /// Дорожка `name`: несжатая, пока есть, иначе сжатая.
    public func audioURL(_ name: String) -> URL {
        let caf = dir.appendingPathComponent("\(name).caf"), m4a = dir.appendingPathComponent("\(name).m4a")
        return fm.fileExists(atPath: caf.path) || !fm.fileExists(atPath: m4a.path) ? caf : m4a
    }

    /// Дописывает название встречи в имя папки. Название узнаём не сразу, поэтому папка создаётся без него.
    @discardableResult
    public func finalize(title: String?) throws -> URL {
        let safe = (title ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return dir }
        let target = Self.free(dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent) \(safe.prefix(80))"))
        try fm.moveItem(at: dir, to: target)
        dir = target
        return dir
    }

    private static func free(_ url: URL) -> URL {
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) (\(n))")
            n += 1
        }
        return candidate
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func read<T: Decodable>(_ name: String) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }
}

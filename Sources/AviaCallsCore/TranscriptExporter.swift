import Foundation

/// Копия транскрипта во внешнюю папку (например, инбокс Obsidian).
/// Имя файла зависит только от начала и названия встречи, поэтому повторная расшифровка перезаписывает тот же файл.
public enum TranscriptExporter {
    /// Папка из настройки transcriptExportDir; пустая строка — выгрузка выключена.
    public static func directory(from setting: String?) -> URL? {
        let path = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Пишет `<dir>/<yyyy-MM-dd-HHmm>-<slug>.md` атомарно (временный файл и rename): синхронизация папки
    /// не увидит недописанный файл.
    @discardableResult
    public static func export(transcript: String, info: MeetingInfo, meetingDir: URL, to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(fileName(start: info.start, title: info.title))
        let text = document(transcript: transcript, meetingDir: meetingDir, start: info.start, participants: info.participants)
        try Data(text.utf8).write(to: target, options: .atomic)
        return target
    }

    /// Что выгружать: вычитанная версия, если она есть и сделана по текущему transcript.md, иначе исходный транскрипт.
    public static func currentTranscript(in meetingDir: URL) -> String? {
        guard let corrected = TranscriptCorrection.currentURL(in: meetingDir) else {
            return try? String(contentsOf: meetingDir.appendingPathComponent("transcript.md"), encoding: .utf8)
        }
        guard let text = try? String(contentsOf: corrected, encoding: .utf8) else { return nil }
        // первая строка — служебный маркер с хешем исходника, в заметке он не нужен
        return text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? text
    }

    public static func fileName(start: Date, title: String?) -> String {
        "\(stamp.string(from: start))-\(slug(title)).md"
    }

    public static func document(transcript: String, meetingDir: URL, start: Date, participants: [String]) -> String {
        """
        ---
        source: aviacalls
        meeting_dir: \(yaml(meetingDir.standardizedFileURL.path))
        recorded: \(recorded.string(from: start))
        participants: [\(participants.map(yaml).joined(separator: ", "))]
        ---

        """ + transcript
    }

    /// Латиница в нижнем регистре, всё прочее — дефисы; не длиннее 60 символов.
    public static func slug(_ title: String?) -> String {
        let t = title ?? ""
        var s = t.applyingTransform(.toLatin, reverse: false) ?? t
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        let words = s.lowercased().filter { !"ʹʺ'’".contains($0) }   // ь/ъ после транслитерации
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        var out = String(words.joined(separator: "-").prefix(60))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "meeting" : out
    }

    /// Строка YAML в двойных кавычках: JSON-строка — валидный YAML-скаляр.
    public static func yaml(_ s: String) -> String {
        let e = JSONEncoder()
        e.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? e.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let stamp = formatter("yyyy-MM-dd-HHmm")
    private static let recorded = formatter("yyyy-MM-dd'T'HH:mm")
}

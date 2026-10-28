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

    /// Пишет `<dir>/<yyyy-MM-dd-HHmm>-<slug>.md` атомарно: временный `.<имя>.tmp` рядом, потом rename.
    @discardableResult
    public static func export(transcript: String, info: MeetingInfo, meetingDir: URL, to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = fileName(start: info.start, title: info.title)
        let target = dir.appendingPathComponent(name), temp = dir.appendingPathComponent(".\(name).tmp")
        let text = document(transcript: transcript, meetingDir: meetingDir, start: info.start, participants: info.participants)
        do {
            try Data(text.utf8).write(to: temp)
            // rename(2) заменяет файл атомарно: под итоговым именем никогда не бывает недописанного файла
            guard rename(temp.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return target
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
        var s = (title ?? "").applyingTransform(.toLatin, reverse: false) ?? (title ?? "")
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        s = s.lowercased().filter { !"ʹʺ'’".contains($0) }   // ь/ъ после транслитерации
        var out = "", dash = false
        for c in s.unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                if dash && !out.isEmpty { out += "-" }
                out.unicodeScalars.append(c)
                dash = false
            } else {
                dash = true
            }
        }
        out = String(out.prefix(60))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "meeting" : out
    }

    /// Строка YAML в двойных кавычках.
    public static func yaml(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where c.value < 0x20 || c.value == 0x7F: out += String(format: "\\u%04X", c.value)
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
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

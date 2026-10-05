import Foundation

public enum TranscriptRenderer {
    public static func render(title: String, start: Date, participants: [String], utterances: [Utterance],
                              screenshots: [Screenshot] = []) -> String {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n\(date.string(from: start))\nУчастники: \(participants.joined(separator: ", "))\n\n"
        // снимки экрана встают в ленту по времени между репликами
        let lines = utterances.map { ($0.start, "\($0.speaker): \($0.text)") } + screenshots.map { ($0.time, "(экран) \($0.path)") }
        for (time, text) in lines.sorted(by: { $0.0 < $1.0 }) {
            let s = Int(time)
            out += String(format: "[%02d:%02d:%02d] ", s / 3600, s / 60 % 60, s % 60) + text + "\n"
        }
        return out
    }
}

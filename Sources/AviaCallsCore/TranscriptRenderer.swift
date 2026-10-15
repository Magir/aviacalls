import Foundation

public enum TranscriptRenderer {
    public static func render(title: String, start: Date, participants: [String], utterances: [Utterance],
                              screenshots: [Screenshot] = []) -> String {
        document(title: title, start: start, participants: participants, utterances: utterances, screenshots: screenshots).text
    }

    public struct Document {
        public let text: String
        public let speakers: [Int: String]
    }

    public static func document(title: String, start: Date, participants: [String], utterances: [Utterance],
                                screenshots: [Screenshot] = []) -> Document {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n\(date.string(from: start))\nУчастники: \(participants.joined(separator: ", "))\n\n"
        // снимки экрана встают в ленту по времени между репликами
        let lines: [(Double, String, String?)] = utterances.map { ($0.start, "\($0.speaker): \($0.text)", $0.speaker) }
            + screenshots.map { ($0.time, "(экран) \($0.path)", nil) }
        var speakers: [Int: String] = [:]
        var lineNumber = out.filter(\.isNewline).count
        for (time, text, speaker) in lines.sorted(by: { $0.0 < $1.0 }) {
            let s = Int(time)
            let line = String(format: "[%02d:%02d:%02d] ", s / 3600, s / 60 % 60, s % 60) + text + "\n"
            if let speaker { speakers[lineNumber] = speaker }
            out += line
            lineNumber += line.filter(\.isNewline).count
        }
        return Document(text: out, speakers: speakers)
    }
}

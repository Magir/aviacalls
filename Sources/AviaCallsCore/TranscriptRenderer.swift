import Foundation

public enum TranscriptRenderer {
    public static func render(title: String, start: Date, participants: [String], utterances: [Utterance]) -> String {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n\(date.string(from: start))\nУчастники: \(participants.joined(separator: ", "))\n\n"
        for u in utterances {
            let s = Int(u.start)
            out += String(format: "[%02d:%02d:%02d] ", s / 3600, s / 60 % 60, s % 60) + "\(u.speaker): \(u.text)\n"
        }
        return out
    }
}

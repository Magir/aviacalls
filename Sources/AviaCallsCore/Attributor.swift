import Foundation

/// Раздаёт имена словам двух дорожек по таймлайну микрофонов и склеивает слова в реплики.
public enum Attributor {
    /// Включение микрофона считаем случившимся на столько секунд раньше, чем увидели: опрос Zoom идёт с задержкой.
    public static var unmuteLead = 0.4
    /// Пока пауза между словами не длиннее этой, говорящий остаётся прежним, даже если включился ещё чей-то микрофон.
    public static var continuityGap = 1.0
    /// Пауза, после которой начинается новая реплика того же человека.
    public static var maxPause = 2.0
    public static let unknownSpeaker = "Неизвестный"

    private enum Mic { case on, off, unknown }

    private struct Replay {
        let events: [TimedEvent]
        var i = 0
        var mics: [String: Mic] = [:]
        var myMic = true   // состояние не прочитали — свою речь не выбрасываем

        mutating func advance(to t: Double) {
            while i < events.count, events[i].t <= t {
                switch events[i].event {
                case .joined(let n): if mics[n] == nil { mics[n] = .unknown }
                case .left(let n): mics[n] = nil
                case .mic(let n, let on): mics[n] = on.map { $0 ? .on : .off } ?? .unknown
                case .myMic(let on): myMic = on
                case .title, .me: break
                }
                i += 1
            }
        }

        func names(_ state: Mic, excluding me: String) -> [String] {
            mics.filter { $0.value == state && $0.key != me }.keys.sorted()
        }
    }

    public static func attribute(mic: [Word], zoom: [Word], timeline: [TimedEvent], myName: String) -> [Utterance] {
        let events = timeline.enumerated().map { i, e -> (Int, TimedEvent) in
            switch e.event {
            case .mic(_, on: .some(true)), .myMic(on: true): return (i, TimedEvent(t: e.t - unmuteLead, event: e.event))
            default: return (i, e)
            }
        }.sorted { ($0.1.t, $0.0) < ($1.1.t, $1.0) }.map(\.1)

        var mine: [(Word, String)] = []
        var replay = Replay(events: events)
        for word in mic.sorted(by: { $0.start < $1.start }) {
            replay.advance(to: (word.start + word.end) / 2)
            if replay.myMic { mine.append((word, myName)) }
        }

        var theirs: [(Word, String)] = []
        replay = Replay(events: events)
        var prev: (speaker: String, end: Double)?
        for word in zoom.sorted(by: { $0.start < $1.start }) {
            replay.advance(to: (word.start + word.end) / 2)
            let on = replay.names(.on, excluding: myName)
            let continuing = prev.flatMap { word.start - $0.end <= continuityGap ? $0.speaker : nil }
            let speaker: String
            if on.count == 1 {
                speaker = on[0]
            } else if on.count > 1 {
                // ponytail: продолжающий фразу остаётся говорящим; реплику-вставку второго человека
                // так можно приписать первому. Лечится подписью по голосу на этапе 2.
                speaker = continuing.flatMap { on.contains($0) ? $0 : nil } ?? on.joined(separator: " / ")
            } else {
                let unknown = replay.names(.unknown, excluding: myName)
                speaker = continuing ?? (unknown.isEmpty ? unknownSpeaker : unknown.map { $0 + "?" }.joined(separator: " / "))
            }
            theirs.append((word, speaker))
            prev = (speaker, word.end)
        }

        return (group(mine) + group(theirs)).sorted { $0.start < $1.start }
    }

    private static func group(_ words: [(Word, String)]) -> [Utterance] {
        var out: [Utterance] = []
        var lastEnd = 0.0
        for (word, speaker) in words {
            if let last = out.last, last.speaker == speaker, word.start - lastEnd <= maxPause {
                out[out.count - 1].text += " " + word.text
            } else {
                out.append(Utterance(start: word.start, speaker: speaker, text: word.text))
            }
            lastEnd = word.end
        }
        return out
    }
}

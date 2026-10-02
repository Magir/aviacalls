import Foundation

/// Раздаёт имена словам двух дорожек по таймлайну микрофонов и склеивает слова в реплики.
public enum Attributor {
    /// Включение микрофона считаем случившимся на столько секунд раньше, чем увидели: опрос Zoom идёт с задержкой.
    public static var unmuteLead = 0.4
    /// Метку говорящего Zoom переставляет с опозданием: человек уже говорит, а метка ещё на предыдущем.
    public static var speakerLead = 1.0
    /// Пока пауза между словами не длиннее этой, говорящий остаётся прежним, даже если включился ещё чей-то микрофон.
    public static var continuityGap = 1.0
    /// Пауза, после которой начинается новая реплика того же человека.
    public static var maxPause = 2.0
    /// Реплика длиннее этого режется на ближайшем конце предложения, чтобы у монолога были таймкоды по ходу.
    public static var maxUtterance = 30.0
    public static let unknownSpeaker = "Неизвестный"

    private enum Mic { case on, off, unknown }

    private struct Replay {
        let events: [TimedEvent]
        var i = 0
        var mics: [String: Mic] = [:]
        var myMic = true   // состояние не прочитали — свою речь не выбрасываем
        var speaker: String?

        mutating func advance(to t: Double) {
            while i < events.count, events[i].t <= t {
                switch events[i].event {
                case .joined(let n): if mics[n] == nil { mics[n] = .unknown }
                case .left(let n): mics[n] = nil
                case .mic(let n, let on): mics[n] = on.map { $0 ? .on : .off } ?? .unknown
                case .myMic(let on): myMic = on
                case .speaker(let n): speaker = n
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
            case .speaker: return (i, TimedEvent(t: e.t - speakerLead, event: e.event))
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
            // метка говорящего от самого Zoom; на себя не смотрим — своего голоса в дорожке Zoom нет
            let active = replay.speaker == myName ? nil : replay.speaker
            let speaker: String
            if on.count == 1 {
                speaker = on[0]
            } else if on.count > 1 {
                // ponytail: продолжающий фразу остаётся говорящим; реплику-вставку второго человека
                // так можно приписать первому. Лечится подписью по голосу на этапе 2.
                speaker = active.flatMap { on.contains($0) ? $0 : nil }
                    ?? continuing.flatMap { on.contains($0) ? $0 : nil } ?? on.joined(separator: " / ")
            } else if let active, replay.mics[active] != .off {
                // микрофоны не прочитались (или этот участник ушёл с экрана), но Zoom сам говорит, кто это
                speaker = active
            } else {
                let unknown = replay.names(.unknown, excluding: myName)
                speaker = continuing ?? (unknown.isEmpty ? unknownSpeaker : unknown.map { $0 + "?" }.joined(separator: " / "))
            }
            theirs.append((word, speaker))
            prev = (speaker, word.end)
        }

        return (group(mine) + group(theirs)).sorted { $0.start < $1.start }
    }

    /// Кто из участников — пользователь, если список участников не открывали: тот, чей микрофон на плитке
    /// переключается вместе с пунктом меню «Выключить звук». nil, если однозначно понять нельзя.
    public static func inferMe(_ timeline: [TimedEvent], window: Double = 2.0) -> String? {
        var changes: [(t: Double, name: String, on: Bool)] = []
        for e in timeline { if case .mic(let name, .some(let on)) = e.event { changes.append((e.t, name, on)) } }
        var score: [String: Int] = [:]
        for e in timeline {
            guard case .myMic(let on) = e.event else { continue }
            let near = Set(changes.filter { abs($0.t - e.t) <= window && $0.on == on }.map(\.name))
            if near.count == 1, let name = near.first { score[name, default: 0] += 1 }
        }
        guard let best = score.values.max(), score.values.filter({ $0 == best }).count == 1 else { return nil }
        return score.first { $0.value == best }?.key
    }

    private static func group(_ words: [(Word, String)]) -> [Utterance] {
        var out: [Utterance] = []
        var lastEnd = 0.0
        for (word, speaker) in words {
            let sentenceEnded = out.last.map { [".", "!", "?", "…"].contains(String($0.text.suffix(1))) } ?? false
            if let last = out.last, last.speaker == speaker, word.start - lastEnd <= maxPause,
               !(sentenceEnded && word.start - last.start >= maxUtterance) {
                out[out.count - 1].text += (word.text.hasPrefix("-") ? "" : " ") + word.text
            } else {
                out.append(Utterance(start: word.start, speaker: speaker, text: word.text))
            }
            lastEnd = word.end
        }
        return out
    }
}

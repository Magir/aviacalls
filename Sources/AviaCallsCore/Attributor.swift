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
    /// Вставка не длиннее стольких слов («ага», «ну да») не разрывает чужую фразу; длиннее — настоящая перебивка.
    public static var maxInterjection = 2
    /// Микрофон открыт не меньше этой доли встречи — фоновый: человек не мьютится вообще, и включённый микрофон
    /// ничего не говорит о том, что он сейчас говорит. На созвоне из пяти-восьми человек такой бывает у одного-двух
    /// (90–99% встречи), и из-за него почти каждая реплика остальных подписывалась двумя именами.
    public static var backgroundShare = 0.8
    /// На встрече короче этого фоновых не ищем: за пару минут «не мьютился» ещё ничего не значит.
    public static var backgroundMinSpan = 600.0
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

        let background = backgroundMics(timeline, until: (mic + zoom).map(\.end).max() ?? 0, excluding: myName)
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
                // Фоновый микрофон уступает тем, кто включил свой, чтобы сказать: раз микрофон включили, значит, говорят.
                // Это догадка, а не факт: владелец фонового микрофона тоже говорит, например спрашивает посреди чужого
                // рассказа, и по микрофонам этого не отличить. Поэтому имя с «?», как у неизвестного состояния микрофона.
                // Если открыты только фоновые, подписываем всеми, как раньше.
                let deliberate = on.filter { !background.contains($0) }
                // продолжающий может быть подписан догадкой («Ann?»): в списке открытых он без «?»
                speaker = active.flatMap { on.contains($0) ? $0 : nil }
                    ?? continuing.flatMap { on.contains($0.hasSuffix("?") ? String($0.dropLast()) : $0) ? $0 : nil }
                    ?? (deliberate.isEmpty || deliberate.count == on.count
                        ? on.joined(separator: " / ") : deliberate.map { $0 + "?" }.joined(separator: " / "))
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

        return group(interleave(mine + theirs))
    }

    /// Участники, у которых микрофон открыт не меньше backgroundShare встречи. Встреча — от первого события до `end`
    /// (последнего слова, если оно позже последнего события). Неизвестное состояние микрофона открытым не считаем.
    static func backgroundMics(_ timeline: [TimedEvent], until end: Double, excluding me: String) -> Set<String> {
        guard let first = timeline.map(\.t).min() else { return [] }
        let last = max(end, timeline.map(\.t).max() ?? end)
        let span = last - first
        guard span >= backgroundMinSpan else { return [] }
        var openSince: [String: Double] = [:]
        var open: [String: Double] = [:]
        func close(_ n: String, at t: Double) {
            if let s = openSince.removeValue(forKey: n) { open[n, default: 0] += t - s }
        }
        for e in timeline.sorted(by: { $0.t < $1.t }) {
            switch e.event {
            case .mic(let n, on: .some(true)): if openSince[n] == nil { openSince[n] = e.t }
            case .mic(let n, _), .left(let n): close(n, at: e.t)
            default: break
            }
        }
        for n in Array(openSince.keys) { close(n, at: last) }
        return Set(open.filter { $0.key != me && $0.value >= backgroundShare * span }.keys)
    }

    /// Слова обеих дорожек в порядке чтения. Склейка по дорожкам ставила вопрос собеседника после ответа на него,
    /// потому что ответ без паузы приклеивался к фразе до вопроса. Теперь поток общий, по времени, с одним исключением:
    /// короткая вставка слушателя ждёт, пока говорящий закончит фразу без паузы, и идёт после неё целиком.
    static func interleave(_ words: [(Word, String)]) -> [(Word, String)] {
        var runs: [[(Word, String)]] = []   // подряд идущие слова одного человека
        for w in words.sorted(by: { $0.0.start < $1.0.start }) {
            if let last = runs.last?.last, last.1 == w.1 { runs[runs.count - 1].append(w) } else { runs.append([w]) }
        }
        var out: [(Word, String)] = []
        var pending: [(Word, String)] = []   // вставки, ждущие конца текущей фразы
        var current: (speaker: String, end: Double)?
        for run in runs {
            let speaker = run[0].1
            if let c = current, speaker == c.speaker, run[0].0.start - c.end <= maxPause {
                out += run
            } else if let c = current, speaker != c.speaker, run.count <= maxInterjection {
                pending += run
                continue
            } else {
                out += pending
                pending = []
                out += run
            }
            current = (speaker, run[run.count - 1].0.end)
        }
        return out + pending
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

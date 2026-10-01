import Foundation

public enum TimelineEvent: Codable, Equatable, Sendable {
    case title(String)
    case joined(String)
    case left(String)
    case mic(name: String, on: Bool?)   // nil — состояние неизвестно
    case myMic(on: Bool)
    case me(String)
}

public struct TimedEvent: Codable, Equatable, Sendable {
    public var t: Double   // секунды от начала записи
    public var event: TimelineEvent
    public init(t: Double, event: TimelineEvent) { self.t = t; self.event = event }
}

/// Превращает поток снимков в события: кто пришёл, ушёл, включил или выключил микрофон.
public struct TimelineBuilder {
    /// Сколько секунд участника нет ни в одном источнике, прежде чем мы на это реагируем.
    public static var goneAfter = 5.0

    public private(set) var myName: String?
    private var title: String?
    private var myMicOn: Bool?
    private var order: [String] = []
    private var present: [String: (mic: Bool?, lastSeen: Double)] = [:]

    public init(myName: String?) { self.myName = myName }

    public mutating func ingest(_ s: ZoomSnapshot, at t: Double) -> [TimedEvent] {
        var out: [TimelineEvent] = []
        if let new = s.title, new != title { title = new; out.append(.title(new)) }
        if let new = s.myMicOn, new != myMicOn { myMicOn = new; out.append(.myMic(on: new)) }
        if let me = s.participants.first(where: \.isMe)?.name, me != myName { myName = me; out.append(.me(me)) }

        for p in s.participants {
            if let cur = present[p.name] {
                let mic = p.micOn ?? cur.mic
                if mic != cur.mic { out.append(.mic(name: p.name, on: mic)) }
                present[p.name] = (mic, t)
            } else {
                order.append(p.name)
                present[p.name] = (p.micOn, t)
                out.append(.joined(p.name))
                out.append(.mic(name: p.name, on: p.micOn))
            }
        }

        let seen = Set(s.participants.map(\.name))
        for name in order where !seen.contains(name) {
            guard let cur = present[name], t - cur.lastSeen > Self.goneAfter else { continue }
            if s.listOpen {
                // список открыт и полон: раз участника там нет, он ушёл
                present[name] = nil
                out.append(.left(name))
            } else if cur.mic != nil {
                // панель закрыта, плитка ушла с экрана: человек, скорее всего, на встрече, но микрофон не видим
                present[name] = (nil, cur.lastSeen)
                out.append(.mic(name: name, on: nil))
            }
        }
        order.removeAll { present[$0] == nil }
        return out.map { TimedEvent(t: t, event: $0) }
    }
}

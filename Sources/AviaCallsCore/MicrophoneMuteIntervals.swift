import Foundation

/// Полуоткрытый интервал [start, end) выключенного микрофона в секундах от начала аудиодорожки.
public struct MicrophoneMuteInterval: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Интервалы, которые нужно заглушить до отправки собственной микрофонной дорожки в облако.
public enum MicrophoneMuteIntervals {
    public static func intervals(timeline: [TimedEvent], offset: Double, duration: Double) -> [MicrophoneMuteInterval] {
        guard offset.isFinite, duration.isFinite, duration > 0 else { return [] }
        let events = timeline.enumerated().compactMap { index, event -> (index: Int, t: Double, on: Bool)? in
            guard event.t.isFinite, case .myMic(let on) = event.event else { return nil }
            return (index, event.t, on)
        }.sorted { $0.t == $1.t ? $0.index < $1.index : $0.t < $1.t }

        var result: [MicrophoneMuteInterval] = []
        var mutedFrom: Double?
        func append(_ start: Double, _ end: Double) {
            let start = max(0, min(duration, start))
            let end = max(0, min(duration, end))
            guard start < end else { return }
            if let last = result.last, start <= last.end {
                result[result.count - 1].end = max(last.end, end)
            } else {
                result.append(MicrophoneMuteInterval(start: start, end: end))
            }
        }

        for (index, event) in events.enumerated() {
            let time = event.t - offset
            if event.on {
                // Закрываем строго в наблюдаемое время unmute. Сдвиг Attributor.unmuteLead здесь
                // раскрыл бы звук, записанный до включения микрофона Zoom.
                if let start = mutedFrom { append(start, time) }
                mutedFrom = nil
            } else if mutedFrom == nil {
                // Первый снимок Zoom приходит позже аудио. Если первый известный статус — mute,
                // не отправляем и начало записи. Первое true оставляет предыдущее состояние неизвестным.
                mutedFrom = index == 0 ? 0 : time
            }
        }
        if let start = mutedFrom { append(start, duration) }
        return result
    }
}

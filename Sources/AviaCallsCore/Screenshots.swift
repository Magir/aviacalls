import Foundation

public struct Screenshot: Codable, Equatable, Sendable {
    public var time: Double   // секунды от начала записи
    public var path: String   // относительно папки встречи
    public init(time: Double, path: String) { self.time = time; self.path = path }
}

/// Решает, какие кадры демонстрации экрана стоит сохранить. Кадр — уменьшенная серая картинка, байт на пиксель.
/// Zoom никак не сообщает о чужой демонстрации, поэтому отличаем слайд от живого видео по поведению:
/// слайд не меняется от кадра к кадру, видео меняется всегда.
public enum Screenshots {
    /// Средняя разница между соседними кадрами (0…255), ниже которой кадр считаем неподвижным. Курсор и мелкая анимация укладываются.
    public static var staticThreshold = 3.0
    /// Разница с последним сохранённым кадром, выше которой это уже другой слайд.
    public static var changeThreshold = 12.0

    public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    public struct Detector {
        private var previous: [UInt8]?
        private var saved: [UInt8]?
        public init() {}

        /// true — этот кадр надо сохранить.
        public mutating func consider(_ frame: [UInt8]) -> Bool {
            defer { previous = frame }
            guard let previous, difference(previous, frame) <= staticThreshold else { return false }
            if let saved, difference(saved, frame) <= changeThreshold { return false }
            saved = frame
            return true
        }
    }
}

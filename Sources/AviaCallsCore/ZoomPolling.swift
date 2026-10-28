import Foundation

/// Синхронное чтение Accessibility выполняется отдельно от UI; медленные опросы не накапливаются.
@MainActor
public final class ZoomPolling {
    private let queue = DispatchQueue(label: "ru.magir.aviacalls.zoom-polling", qos: .userInitiated)
    private var reading = false

    public init() {}

    @discardableResult
    /// `read` выполняется на фоновой очереди; что читать, решает вызывающий на каждом опросе.
    /// `receive` получает и момент начала чтения: события встречи помечаем им, а не временем, когда дошла очередь.
    public func poll<Value>(_ read: @escaping () -> Value, receive: @escaping @MainActor (Value, Date) -> Void) -> Bool {
        guard !reading else { return false }
        reading = true
        queue.async {
            let at = Date()
            let value = autoreleasepool { read() }
            Task { @MainActor in
                self.reading = false
                receive(value, at)
            }
        }
        return true
    }
}

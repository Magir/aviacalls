import Foundation

/// Синхронное чтение Accessibility выполняется отдельно от UI; медленные опросы не накапливаются.
@MainActor
public final class ZoomPolling {
    private let queue = DispatchQueue(label: "ru.magir.aviacalls.zoom-polling", qos: .userInitiated)
    private let read: () -> ZoomRawSnapshot?
    private var reading = false

    public init(read: @escaping () -> ZoomRawSnapshot?) { self.read = read }

    @discardableResult
    public func poll(receive: @escaping @MainActor (ZoomRawSnapshot?) -> Void) -> Bool {
        guard !reading else { return false }
        reading = true
        let read = self.read
        queue.async {
            let snapshot = autoreleasepool { read() }
            Task { @MainActor in
                self.reading = false
                receive(snapshot)
            }
        }
        return true
    }
}

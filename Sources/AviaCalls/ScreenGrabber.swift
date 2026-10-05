import AppKit
import AviaCallsCore
import ScreenCaptureKit

/// Снимки демонстрации экрана. Раз в несколько секунд берёт кадр окна Zoom (или всего экрана, когда показываешь ты)
/// и сохраняет его, только если картинка неподвижна и отличается от прошлого сохранённого — см. Screenshots.Detector.
@MainActor
final class ScreenGrabber {
    static let interval = 3.0
    static let maxWidth = 1600

    private var timer: Timer?
    private var detector = Screenshots.Detector()
    private var dir: URL?
    private var start = Date()
    private var busy = false
    private(set) var saved: [Screenshot] = []
    /// Для проверки без встречи: снимать экран целиком, как при своей демонстрации.
    var forceDisplay = false

    nonisolated static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    func begin(dir: URL, start: Date) {
        self.dir = dir
        self.start = start
        detector = Screenshots.Detector()
        saved = []
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func end() -> [Screenshot] {
        timer?.invalidate()
        timer = nil
        dir = nil
        return saved
    }

    private func tick() async {
        guard !busy, let dir, Self.allowed else { return }
        busy = true
        defer { busy = false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let zoom = content.windows.filter { $0.owningApplication?.bundleIdentifier == ZoomReader.bundleID }
        let filter: SCContentFilter
        if forceDisplay || zoom.contains(where: { $0.title?.hasPrefix("zoom share") == true }), let display = content.displays.first {
            // показываю я: окна встречи нет, снимаем экран целиком
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else if let window = zoom.filter({ $0.title != "Zoom Workplace" && $0.frame.width > 400 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            return
        }
        let config = SCStreamConfiguration()
        let pixelScale = CGFloat(filter.pointPixelScale)
        let scale = min(1, CGFloat(Self.maxWidth) / max(1, filter.contentRect.width * pixelScale))
        config.width = Int(filter.contentRect.width * pixelScale * scale)
        config.height = Int(filter.contentRect.height * pixelScale * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
        guard detector.consider(Self.thumbnail(image)) else { return }

        let t = Date().timeIntervalSince(start)
        let s = Int(t)
        let name = String(format: "screens/%02d-%02d-%02d.jpg", s / 3600, s / 60 % 60, s % 60)
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]),
              (try? data.write(to: url)) != nil else { return }
        saved.append(Screenshot(time: t, path: name))
    }

    /// Серая картинка 32×18 — на ней детектор сравнивает кадры.
    static func thumbnail(_ image: CGImage, width: Int = 32, height: Int = 18) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}

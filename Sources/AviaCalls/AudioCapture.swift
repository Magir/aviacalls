import Foundation

/// Пишет две дорожки встречи: mic.caf и zoom.caf.
final class AudioCapture {
    private var mic: MicCapture?
    private var zoom: ZoomTap?
    private var micWriter: TrackWriter?
    private var zoomWriter: TrackWriter?

    /// Пошёл ли звук Zoom. false через 15 секунд после старта — скорее всего, нет разрешения на захват звука.
    var zoomAlive: Bool { zoomWriter?.alive ?? false }

    func start(dir: URL, at start: Date) throws {
        let zoomWriter = try TrackWriter(url: dir.appendingPathComponent("zoom.caf"), start: start)
        let micWriter = try TrackWriter(url: dir.appendingPathComponent("mic.caf"), start: start)
        let zoom = ZoomTap(writer: zoomWriter)
        let mic = MicCapture(writer: micWriter)
        zoom.start()
        do { try mic.start() } catch { zoom.stop(); throw error }
        (self.zoom, self.mic, self.zoomWriter, self.micWriter) = (zoom, mic, zoomWriter, micWriter)
    }

    func stop() -> (micOffset: Double, zoomOffset: Double) {
        mic?.stop()
        zoom?.stop()
        let offsets = (micWriter?.close() ?? 0, zoomWriter?.close() ?? 0)
        (mic, zoom, micWriter, zoomWriter) = (nil, nil, nil, nil)
        return offsets
    }
}

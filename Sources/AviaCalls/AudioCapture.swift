import Foundation

/// Пишет две дорожки встречи: mic.caf и zoom.caf.
final class AudioCapture {
    private var mic: MicCapture?
    private var zoom: ZoomTap?
    private var micWriter: TrackWriter?
    private var zoomWriter: TrackWriter?
    private let micQueue = DispatchQueue(label: "aviacalls.mic")

    /// Пошёл ли звук Zoom. false через 15 секунд после старта — скорее всего, нет разрешения на захват звука.
    var zoomAlive: Bool { zoomWriter?.alive ?? false }
    var micAlive: Bool { micWriter?.alive ?? false }
    /// Сколько секунд назад в дорожку последний раз писался звук; nil — ещё не писался.
    func zoomIdle(_ now: Date) -> Double? { zoomWriter?.lastWritten.map { now.timeIntervalSince($0) } }
    func micIdle(_ now: Date) -> Double? { micWriter?.lastWritten.map { now.timeIntervalSince($0) } }

    func start(dir: URL, at start: Date) throws {
        let zoomWriter = try TrackWriter(url: dir.appendingPathComponent("zoom.caf"), start: start)
        let micWriter = try TrackWriter(url: dir.appendingPathComponent("mic.caf"), start: start)
        let zoom = ZoomTap(writer: zoomWriter)
        let mic = MicCapture(writer: micWriter)
        // порядок важен: эхоподавление при старте перестраивает аудиоустройства, и уже запущенный tap замолкает
        zoom.start()
        // эхоподавление во время звонка стартует до 7 секунд; не держим этим ни главный поток, ни дорожку Zoom
        micQueue.async { do { try mic.start() } catch { NSLog("MicCapture: не стартовал: %@", "\(error)") } }
        (self.zoom, self.mic, self.zoomWriter, self.micWriter) = (zoom, mic, zoomWriter, micWriter)
    }

    func stop() -> (micOffset: Double, zoomOffset: Double) {
        micQueue.sync { mic?.stop() }
        zoom?.stop()
        let offsets = (micWriter?.close() ?? 0, zoomWriter?.close() ?? 0)
        (mic, zoom, micWriter, zoomWriter) = (nil, nil, nil, nil)
        return offsets
    }
}

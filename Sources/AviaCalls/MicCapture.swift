import AVFoundation
import CoreAudio

/// Микрофон. Когда звук идёт через встроенные динамики, включает системное эхоподавление,
/// чтобы голоса собеседников не попадали в дорожку пользователя. С наушниками оно не нужно
/// и только задерживает старт (на AirPods — до 12 секунд против 3).
final class MicCapture {
    private let writer: TrackWriter
    private let queue = DispatchQueue(label: "aviacalls.mic.engine")
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var running = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var watchdog: DispatchSourceTimer?
    private var lastAttempt = Date.distantPast
    private static var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init(writer: TrackWriter) { self.writer = writer }

    func start() {
        queue.sync {
            running = true
            // переключили вывод с наушников на динамики или обратно — пересматриваем, нужно ли эхоподавление
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
            outputListener = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, queue, block)
            restart()
            // Сторож: движок не стартовал, остановился сам или молчит — поднимаем заново, пока не заработает.
            // Без него неудачный старт был окончательным: Zoom открыл микрофон, AirPods ушли в режим гарнитуры
            // (24 кГц), движок под 48 кГц упал с −10868, и микрофон молчал всю встречу (29.10.2026)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.watch() }
            timer.resume()
            watchdog = timer
        }
    }

    func stop() {
        queue.sync {
            running = false
            watchdog?.cancel()
            watchdog = nil
            if let outputListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, queue, outputListener) }
            outputListener = nil
            teardown()
        }
    }

    /// Каждый раз поднимаем новый движок: после смены устройства (подключили AirPods, гарнитура ушла
    /// в режим разговора) старый движок перезапустить не удаётся — ошибка −10868.
    private func run() throws {
        teardown()
        let engine = AVAudioEngine()
        // ручка: defaults write ru.magir.aviacalls micVoiceProcessing -bool YES|NO; без неё решаем по устройству вывода
        if UserDefaults.standard.object(forKey: "micVoiceProcessing") as? Bool ?? Self.outputIsBuiltInSpeakers() {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // без этого система приглушает звук остальных приложений, включая сам Zoom
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let writer = self.writer
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in writer.append(buffer) }
        // движок кладём в поле до start(): не стартовавший тоже должен уйти через teardown(), а не умереть на выходе из функции
        self.engine = engine
        try engine.start()
        // перезапускать прямо из уведомления нельзя: движок в этот момент занят
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // сторож мог успеть поднять новый движок между остановкой старого и этим уведомлением
            self?.queue.async { if self?.engine?.isRunning != true { self?.restart() } }
        }
    }

    private func restart() {
        guard running else { return }
        // время ставим после run(): старт с эхоподавлением держит очередь до 12 секунд, и сторож не должен счесть их тишиной
        defer { lastAttempt = Date() }
        // устройство ещё переключается — следующую попытку сделает сторож; тишину на это время TrackWriter добьёт сам
        do { try run() } catch { NSLog("MicCapture: старт не удался: %@", "\(error)") }
    }

    /// Раз в секунду. Не работает — сразу новая попытка; работает, но звука нет 5 секунд — тоже.
    private func watch() {
        let heard = max(writer.lastWritten ?? .distantPast, lastAttempt)
        if engine?.isRunning != true || Date().timeIntervalSince(heard) > 5 { restart() }
    }

    static func outputIsBuiltInSpeakers() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &size, &device) == noErr else { return true }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return true }
        // ponytail: проводные наушники в гнезде мака тоже «встроенное» устройство — для них эхоподавление включится зря
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let old = engine else { return }
        old.inputNode.removeTap(onBus: 0)
        old.stop()
        // Остановленный движок с эхоподавлением всё равно глушит микрофон: новый движок без него, пока жив старый,
        // пишет −90 дБ вместо −60 (вывод переключили с динамиков на наушники или монитор). Выключаем сразу, не через 30 с
        if old.inputNode.isVoiceProcessingEnabled { try? old.inputNode.setVoiceProcessingEnabled(false) }
        engine = nil
        // Освобождать движок сразу нельзя: при смене устройства AVAudioIOUnit ещё несколько секунд дёргает его из своей
        // очереди, не удерживая, и приложение падает в IOUnitPropertyListener (крэши 09.10 и 15.10.2026).
        // ponytail: держим остановленный движок 30 с, ресурсы устройства он уже отпустил в stop()
        queue.asyncAfter(deadline: .now() + 30) { _ = old }
    }
}

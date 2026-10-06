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
    private static var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init(writer: TrackWriter) { self.writer = writer }

    func start() throws {
        try queue.sync {
            running = true
            try run()
            // переключили вывод с наушников на динамики или обратно — пересматриваем, нужно ли эхоподавление
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart(attempt: 1) }
            outputListener = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, queue, block)
        }
    }

    func stop() {
        queue.sync {
            running = false
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
        try engine.start()
        self.engine = engine
        // перезапускать прямо из уведомления нельзя: движок в этот момент занят
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart(attempt: 1) }
        }
    }

    private func restart(attempt: Int) {
        guard running else { return }
        do { try run() } catch {
            NSLog("MicCapture: перезапуск %d не удался: %@", attempt, "\(error)")
            // устройство ещё переключается; тишину на это время TrackWriter добьёт сам
            if attempt < 10 { queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart(attempt: attempt + 1) } }
        }
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
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

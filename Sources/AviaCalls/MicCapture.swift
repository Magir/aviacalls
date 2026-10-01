import AVFoundation

/// Микрофон с системным эхоподавлением, чтобы голоса из динамиков не попадали в дорожку пользователя.
final class MicCapture {
    private let writer: TrackWriter
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    init(writer: TrackWriter) { self.writer = writer }

    func start() throws {
        // ручка на случай, если эхоподавление мешает Zoom: defaults write com.magir.aviacalls micVoiceProcessing -bool NO
        if UserDefaults.standard.object(forKey: "micVoiceProcessing") as? Bool ?? true {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // без этого система приглушает звук остальных приложений, включая сам Zoom
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        try run()
        // сменился микрофон — движок останавливается сам, поднимаем заново
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            try? self?.run()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func run() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in writer.append(buffer) }
        try engine.start()
    }
}

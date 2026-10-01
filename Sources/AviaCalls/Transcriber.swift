import AviaCallsCore
import Foundation
import WhisperKit

/// Локальная транскрибация. Модель скачивается один раз при первом запуске, дальше сеть не нужна.
actor Transcriber {
    // ручка: defaults write com.magir.aviacalls whisperModel <имя>
    static var model: String { UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo" }
    private var pipe: WhisperKit?

    func words(audio: URL, offset: Double) async throws -> [Word] {
        if pipe == nil { pipe = try await WhisperKit(WhisperKitConfig(model: Self.model)) }
        // VAD режет тишину: на длинных паузах Whisper выдумывает текст
        let options = DecodingOptions(task: .transcribe, language: nil, detectLanguage: true,
                                      skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        let results = try await pipe!.transcribe(audioPath: audio.path, decodeOptions: options)
        return results.flatMap(\.allWords).compactMap { w in
            let text = w.word.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : Word(start: Double(w.start) + offset, end: Double(w.end) + offset, text: text)
        }
    }
}

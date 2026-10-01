import AviaCallsCore
import Foundation
import WhisperKit

/// Локальная транскрибация. Сеть не нужна: модель ставится заранее, см. WhisperModel.
actor Transcriber {
    private var pipe: WhisperKit?

    func words(audio: URL, offset: Double) async throws -> [Word] {
        guard WhisperModel.isInstalled else { throw ModelMissing() }
        if pipe == nil { pipe = try await WhisperKit(WhisperModel.config()) }
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

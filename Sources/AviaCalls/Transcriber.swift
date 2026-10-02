import AviaCallsCore
import Foundation
import WhisperKit

/// Локальная транскрибация. Сеть не нужна: модель ставится заранее, см. WhisperModel.
actor Transcriber {
    private var pipe: WhisperKit?

    /// `levels` — громкость дорожки (Pipeline.levels): по ней находим, где слушать язык, и не тратим время на пустую дорожку.
    func words(audio: URL, offset: Double, levels: [Float]) async throws -> [Word] {
        guard WhisperModel.isInstalled else { throw ModelMissing() }
        guard let loudest = SilenceGate.loudestWindow(levels, seconds: 30) else { return [] }
        if pipe == nil { pipe = try await WhisperKit(WhisperModel.config()) }
        // ручки: defaults write com.magir.aviacalls whisperLanguage ru | whisperChunking vad
        // Язык определяем один раз по самому громкому куску и держим на всю дорожку. Если определять в каждом
        // 30-секундном окне, часть окон русской речи Whisper принимает за украинский или теряет целиком.
        var language = UserDefaults.standard.string(forKey: "whisperLanguage")
        if language == nil {
            let clip = try AudioProcessor.loadAudio(fromPath: audio.path, startTime: loudest, endTime: loudest + 30)
            language = try await pipe!.detectLangauge(audioArray: AudioProcessor.convertBufferToArray(buffer: clip)).language
            NSLog("Transcriber: язык дорожки %@ — %@", audio.lastPathComponent, language ?? "?")
        }
        // Сплошная расшифровка: на встрече 2026-10-02 нарезка по паузам (vad) теряла больше текста и шла дольше.
        let chunking: ChunkingStrategy = UserDefaults.standard.string(forKey: "whisperChunking") == "vad" ? .vad : .none
        // noSpeechThreshold выключен: с ним Whisper целиком выбрасывал 30-секундные окна с громкой речью
        // (модель turbo плохо оценивает «нет речи»). Выдуманный на тишине текст убирает SilenceGate.
        let options = DecodingOptions(task: .transcribe, language: language, detectLanguage: false,
                                      skipSpecialTokens: true, wordTimestamps: true, noSpeechThreshold: nil, chunkingStrategy: chunking)
        func convert(_ results: [TranscriptionResult], shift: Double) -> [Word] {
            results.flatMap(\.allWords).compactMap { w in
                let text = w.word.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : Word(start: Double(w.start) + shift, end: Double(w.end) + shift, text: text)
            }
        }
        var words = convert(try await pipe!.transcribe(audioPath: audio.path, decodeOptions: options), shift: offset)

        // Whisper время от времени теряет 30-секундное окно целиком, каждый прогон в новом месте.
        // Громкие куски, оставшиеся без слов, расшифровываем повторно по отдельности.
        for gap in SilenceGate.speechGaps(words: words, levels: levels, offset: offset) {
            let from = max(0, gap.start - offset - 1)
            let clip = try AudioProcessor.loadAudio(fromPath: audio.path, startTime: from, endTime: gap.end - offset + 1)
            let again = try await pipe!.transcribe(audioArray: AudioProcessor.convertBufferToArray(buffer: clip), decodeOptions: options)
            let recovered = convert(again, shift: offset + from).filter { ($0.start + $0.end) / 2 >= gap.start && ($0.start + $0.end) / 2 <= gap.end }
            NSLog("Transcriber: %@, пропуск %.0f–%.0f с: дорасшифровано %d слов", audio.lastPathComponent, gap.start, gap.end, recovered.count)
            words += recovered
        }
        return words.sorted { $0.start < $1.start }
    }
}

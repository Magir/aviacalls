import AviaCallsCore
import Foundation
import WhisperKit

/// Локальная транскрибация. Сеть не нужна: модель ставится заранее, см. WhisperModel.
actor Transcriber {
    private var pipe: WhisperKit?
    /// Доля речи в дорожке, ниже которой расшифровываем склейку кусков речи, а не всю дорожку.
    static let sparseShare = 0.5

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
        // noSpeechThreshold выключен: с ним Whisper целиком выбрасывал 30-секундные окна с громкой речью
        // (модель turbo плохо оценивает «нет речи»). Выдуманный на тишине текст убирает SilenceGate.
        let options = DecodingOptions(task: .transcribe, language: language, detectLanguage: false,
                                      skipSpecialTokens: true, wordTimestamps: true, noSpeechThreshold: nil,
                                      chunkingStrategy: UserDefaults.standard.string(forKey: "whisperChunking") == "vad" ? .vad : ChunkingStrategy.none)
        func convert(_ results: [TranscriptionResult], shift: Double) -> [Word] {
            results.flatMap(\.allWords).compactMap { w in
                let text = w.word.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : Word(start: Double(w.start) + shift, end: Double(w.end) + shift, text: text)
            }
        }
        var words: [Word]
        let speech = SilenceGate.speechChunks(levels, maxLength: .infinity)
        let share = speech.reduce(0) { $0 + $1.end - $1.start } / (Double(levels.count) * SilenceGate.frame)
        // Сплошной разговор расшифровываем целиком: так точнее всего (проверено на стендапе против Fireflies).
        // Редкую речь (свой микрофон, 90% тишины) — только куски с речью, склеенные через секунду тишины:
        // на пустых окнах Whisper сбивается и выдаёт мусор, а резать на отдельные короткие куски хуже: теряется контекст.
        if share < Self.sparseShare {
            NSLog("Transcriber: %@ — речи %.0f%%, склеиваю %d кусков", audio.lastPathComponent, share * 100, speech.count)
            let gap = [Float](repeating: 0, count: 16000)
            var condensed: [Float] = []
            var pieces: [(at: Double, from: Double, length: Double)] = []
            for chunk in speech {
                let clip = AudioProcessor.convertBufferToArray(buffer: try AudioProcessor.loadAudio(fromPath: audio.path, startTime: chunk.start, endTime: chunk.end))
                pieces.append((Double(condensed.count) / 16000, chunk.start, Double(clip.count) / 16000))
                condensed += clip + gap
            }
            // время слова из склейки возвращаем в шкалу дорожки
            words = convert(try await pipe!.transcribe(audioArray: condensed, decodeOptions: options), shift: 0).compactMap { w in
                guard let piece = pieces.last(where: { $0.at <= w.start }) else { return nil }
                let shift = offset + piece.from - piece.at
                return Word(start: w.start + shift, end: min(w.end, piece.at + piece.length + 1) + shift, text: w.text)
            }
        } else {
            words = convert(try await pipe!.transcribe(audioPath: audio.path, decodeOptions: options), shift: offset)
        }

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

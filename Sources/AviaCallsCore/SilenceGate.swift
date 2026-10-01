import Foundation

/// Выбрасывает слова, под которыми в записи тишина: на тишине Whisper выдумывает «Thank you», «Продолжение следует».
public enum SilenceGate {
    /// Длина одного отсчёта громкости, секунды.
    public static let frame = 0.1
    /// Громкость (RMS, 1.0 — полная шкала), ниже которой считаем тишиной. Около −50 дБ: на живой записи
    /// выдуманные слова были тише −55 дБ, настоящая речь громче −40 дБ.
    public static var threshold: Float = 0.003
    /// Запас вокруг слова: Whisper ошибается с границами слов на пару десятых секунды.
    public static var margin = 0.3

    /// `levels` — громкость дорожки по отсчётам длиной `frame`; `offset` — время начала дорожки в шкале слов.
    public static func keep(_ words: [Word], levels: [Float], offset: Double) -> [Word] {
        words.filter { word in
            let from = max(0, Int(((word.start - offset - margin) / frame).rounded(.down)))
            let to = min(levels.count, Int(((word.end - offset + margin) / frame).rounded(.up)))
            return from < to && levels[from..<to].contains { $0 >= threshold }
        }
    }
}

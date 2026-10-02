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

    /// Начало (в секундах от начала дорожки) самого громкого окна длиной `seconds` — по нему определяем язык.
    /// nil, если во всей дорожке нет ничего громче порога: расшифровывать нечего.
    public static func loudestWindow(_ levels: [Float], seconds: Double) -> Double? {
        guard levels.contains(where: { $0 >= threshold }) else { return nil }
        let size = min(levels.count, Int(seconds / frame))
        var sum = levels[..<size].reduce(0, +), best = sum, bestStart = 0
        for i in stride(from: size, to: levels.count, by: 1) {
            sum += levels[i] - levels[i - size]
            if sum > best { best = sum; bestStart = i - size + 1 }
        }
        return Double(bestStart) * frame
    }

    /// Промежутки без слов, в которых на записи явно говорят: Whisper иногда целиком теряет 30-секундное окно.
    /// Времена — в шкале слов. Такие куски стоит расшифровать повторно по отдельности.
    public static func speechGaps(words: [Word], levels: [Float], offset: Double,
                                  minGap: Double = 12, minLoudShare: Double = 0.3) -> [(start: Double, end: Double)] {
        let sorted = words.sorted { $0.start < $1.start }
        var edges: [(Double, Double)] = []
        var cursor = offset
        for word in sorted {
            edges.append((cursor, word.start))
            cursor = max(cursor, word.end)
        }
        edges.append((cursor, offset + Double(levels.count) * frame))
        return edges.filter { start, end in
            guard end - start >= minGap else { return false }
            let from = max(0, Int(((start - offset) / frame).rounded())), to = min(levels.count, Int(((end - offset) / frame).rounded()))
            guard from < to else { return false }
            let loud = levels[from..<to].filter { $0 >= threshold }.count
            return Double(loud) / Double(to - from) >= minLoudShare
        }.map { (start: $0.0, end: $0.1) }
    }

    /// `levels` — громкость дорожки по отсчётам длиной `frame`; `offset` — время начала дорожки в шкале слов.
    public static func keep(_ words: [Word], levels: [Float], offset: Double) -> [Word] {
        words.filter { word in
            let from = max(0, Int(((word.start - offset - margin) / frame).rounded(.down)))
            let to = min(levels.count, Int(((word.end - offset + margin) / frame).rounded(.up)))
            return from < to && levels[from..<to].contains { $0 >= threshold }
        }
    }
}

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

    /// Куски дорожки, где есть речь, с отступом `pad` по краям и не длиннее `maxLength` секунд.
    /// Паузы короче `joinGap` не разрывают кусок; длинная речь режется в самом тихом месте последней трети куска.
    /// Расшифровывать такие куски по отдельности надёжнее, чем всю дорожку: на пустых окнах Whisper сбивается.
    public static func speechChunks(_ levels: [Float], maxLength: Double, pad: Double = 0.4, joinGap: Double = 0.6,
                                    minLength: Double = 0.3) -> [(start: Double, end: Double)] {
        // 1. непрерывные участки громкости
        var regions: [(Int, Int)] = []
        var start: Int?
        for (i, level) in levels.enumerated() {
            if level >= threshold { if start == nil { start = i } }
            else if let s = start { regions.append((s, i)); start = nil }
        }
        if let s = start { regions.append((s, levels.count)) }
        // 2. склейка через короткие паузы
        var merged: [(Int, Int)] = []
        for r in regions {
            if let last = merged.last, Double(r.0 - last.1) * frame < joinGap { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
        }
        merged = merged.filter { Double($0.1 - $0.0) * frame >= minLength }
        // 3. длинные режем в самом тихом месте последней трети допустимой длины
        let maxFrames = maxLength.isFinite ? Int(maxLength / frame) : Int.max
        var out: [(start: Double, end: Double)] = []
        for var r in merged {
            while r.1 - r.0 > maxFrames {
                let from = r.0 + maxFrames * 2 / 3, to = r.0 + maxFrames
                let cut = (from..<to).min { levels[$0] < levels[$1] } ?? to
                out.append((Double(r.0) * frame - pad, Double(cut) * frame + pad))
                r.0 = cut
            }
            out.append((Double(r.0) * frame - pad, Double(r.1) * frame + pad))
        }
        return out.map { (max(0, $0.start), $0.end) }
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

import Foundation

/// Выбрасывает то, что Whisper выдумывает на шуме и обрывках: дежурные фразы («Продолжение следует», «Thank you»)
/// и короткие обрывки, в которых модель сама не уверена. Работает после SilenceGate, по сохранённым вероятностям слов,
/// поэтому пороги можно крутить без повторной расшифровки.
public enum HallucinationGate {
    /// Обрывок: не длиннее стольких слов подряд (паузы между словами короче Attributor.maxPause)…
    public static var maxFragmentWords = 2
    /// …со средней уверенностью ниже этой — выбрасываем. Длинную фразу не трогаем, даже неуверенную.
    /// Пороги сняты с двух встреч 2026-10-28: настоящее одинокое «Спасибо.» имело 0,27, «вроде получше стало» — 0,26
    /// на три слова, выдуманное «и» — 0,12. На дорожке Zoom уверенность в целом ниже, чем на микрофоне: звук сжатый.
    public static var minFragmentProbability: Float = 0.2
    /// Классика Whisper на тишине и шуме, в нормализованном виде: строчные, без знаков, ё → е. Уверенность тут не помогает:
    /// у выдуманного «Продолжение следует…» на живой записи она была 0,84. Одинокого «Спасибо» в списке нет: на встрече
    /// «Ревью» оба таких были настоящими, а выдуманные на тишине убирает SilenceGate. Английское «Thank you» на русской
    /// встрече всегда выдумано.
    static let phrases: Set<String> = [
        "продолжение следует",
        "субтитры сделал dimatorzok", "субтитры создавал dimatorzok", "редактор субтитров асемкин корректор аегорова",
        "thank you", "thanks for watching", "thank you for watching",
    ]

    public static func keep(_ words: [Word]) -> [Word] {
        var out: [Word] = []
        var run: [Word] = []
        func flush() { if !isJunk(run) { out += run }; run = [] }
        for word in words.sorted(by: { $0.start < $1.start }) {
            if let last = run.last, word.start - last.end > Attributor.maxPause { flush() }
            run.append(word)
        }
        flush()
        return out
    }

    static func isJunk(_ run: [Word]) -> Bool {
        guard !run.isEmpty else { return false }
        if phrases.contains(normalize(run.map(\.text).joined(separator: " "))) { return true }
        let ps = run.compactMap(\.p)
        guard ps.count == run.count, run.count <= maxFragmentWords else { return false }
        return ps.reduce(0, +) / Float(ps.count) < minFragmentProbability
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }
}

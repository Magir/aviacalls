import Testing
@testable import AviaCallsCore

private func w(_ start: Double, _ end: Double, _ text: String = "x") -> Word { Word(start: start, end: end, text: text) }
private let loud: Float = 0.03, quiet: Float = 0.0001

@Suite struct SilenceGateTests {
    // уровни по 0,1 с: секунда тишины, секунда речи, секунда тишины
    let levels = [Float](repeating: quiet, count: 10) + [Float](repeating: loud, count: 10) + [Float](repeating: quiet, count: 10)

    @Test func dropsWordOverSilence() {
        #expect(SilenceGate.keep([w(0.2, 0.5), w(2.5, 2.9)], levels: levels, offset: 0).isEmpty)
    }

    @Test func keepsWordOverSpeech() {
        #expect(SilenceGate.keep([w(1.2, 1.6)], levels: levels, offset: 0) == [w(1.2, 1.6)])
    }

    @Test func keepsQuietWordRightBeforeSpeech() {
        // Whisper ставит начало первого слова фразы раньше, чем звук реально начался
        #expect(SilenceGate.keep([w(0.6, 0.8)], levels: levels, offset: 0) == [w(0.6, 0.8)])
    }

    @Test func wordTimesAreShiftedByTrackOffset() {
        #expect(SilenceGate.keep([w(6.2, 6.6)], levels: levels, offset: 5) == [w(6.2, 6.6)])
        #expect(SilenceGate.keep([w(1.2, 1.6)], levels: levels, offset: 5).isEmpty)
    }

    @Test func findsLoudestWindow() {
        // уровни по 0,1 с: секунда тишины, секунда речи, секунда тишины
        #expect(SilenceGate.loudestWindow(levels, seconds: 1) == 1.0)
        #expect(SilenceGate.loudestWindow(levels, seconds: 30) == 0)        // окно длиннее записи
        #expect(SilenceGate.loudestWindow([Float](repeating: quiet, count: 50), seconds: 1) == nil)   // речи нет вовсе
        #expect(SilenceGate.loudestWindow([], seconds: 1) == nil)
    }

    @Test func findsLoudStretchesWhisperLeftWithoutWords() {
        // минута записи: речь идёт с 5-й по 55-ю секунду, слова есть только в начале и в конце
        let speech = [Float](repeating: quiet, count: 50) + [Float](repeating: loud, count: 500) + [Float](repeating: quiet, count: 50)
        let words = [w(5, 6), w(6.5, 7), w(50, 51)]
        let gaps = SilenceGate.speechGaps(words: words, levels: speech, offset: 0)
        #expect(gaps.count == 1)
        #expect(gaps.first?.start == 7)
        #expect(gaps.first?.end == 50)
    }

    @Test func silentOrShortGapsAreNotReported() {
        let silentMiddle = [Float](repeating: loud, count: 100) + [Float](repeating: quiet, count: 400) + [Float](repeating: loud, count: 100)
        #expect(SilenceGate.speechGaps(words: [w(1, 9), w(51, 59)], levels: silentMiddle, offset: 0).isEmpty)
        let allLoud = [Float](repeating: loud, count: 600)
        #expect(SilenceGate.speechGaps(words: [w(0, 20), w(25, 60)], levels: allLoud, offset: 0).isEmpty)   // пауза 5 с — обычное дело
    }

    @Test func reportsSpeechBeforeFirstAndAfterLastWord() {
        let allLoud = [Float](repeating: loud, count: 600)
        let gaps = SilenceGate.speechGaps(words: [w(120, 125)], levels: allLoud, offset: 100)   // дорожка началась на 100-й секунде
        #expect(gaps.map(\.start) == [100, 125])
        #expect(gaps.map(\.end) == [120, 160])
        #expect(SilenceGate.speechGaps(words: [], levels: allLoud, offset: 0).map(\.end) == [60])
    }

    @Test func wordPastEndOfAudioIsDropped() {
        #expect(SilenceGate.keep([w(10, 11)], levels: levels, offset: 0).isEmpty)
    }
}

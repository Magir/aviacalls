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

    @Test func wordPastEndOfAudioIsDropped() {
        #expect(SilenceGate.keep([w(10, 11)], levels: levels, offset: 0).isEmpty)
    }
}

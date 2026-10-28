import Testing
@testable import AviaCallsCore

@Suite struct HallucinationGateTests {
    private func w(_ start: Double, _ text: String, p: Float? = nil) -> Word { Word(start: start, end: start + 0.4, text: text, p: p) }

    @Test func dropsKnownWhisperPhrases() {
        let words = [w(1, "Продолжение", p: 0.9), w(1.5, "следует...", p: 0.9), w(10, "привет", p: 0.9), w(20, "Thank", p: 0.9), w(20.3, "you.", p: 0.9)]
        #expect(HallucinationGate.keep(words).map(\.text) == ["привет"])
    }

    @Test func keepsPhraseInsideRealSpeech() {
        let words = [w(1, "спасибо", p: 0.9), w(1.5, "всем,", p: 0.9), w(2, "пока", p: 0.9)]
        #expect(HallucinationGate.keep(words).count == 3)
    }

    @Test func keepsLoneRussianThanks() {
        // на живой встрече одинокое «Спасибо.» с уверенностью 0,27 было настоящим; выдуманное на тишине убирает SilenceGate
        let words = [w(1, "Спасибо.", p: 0.27)]
        #expect(HallucinationGate.keep(words) == words)
    }

    @Test func dropsShortUncertainFragment() {
        let words = [w(1, "А.", p: 0.1), w(10, "мы", p: 0.2), w(10.5, "решили", p: 0.9), w(11, "так", p: 0.9)]
        #expect(HallucinationGate.keep(words).map(\.text) == ["мы", "решили", "так"])
    }

    @Test func keepsLongRunEvenIfUncertain() {
        let words = (0..<6).map { w(Double($0) * 0.5, "слово", p: 0.1) }
        #expect(HallucinationGate.keep(words).count == 6)
    }

    @Test func keepsWordsWithoutProbability() {
        // старые segments.json записаны без вероятностей
        let words = [w(1, "А.")]
        #expect(HallucinationGate.keep(words) == words)
    }
}

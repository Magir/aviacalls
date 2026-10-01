import Testing
@testable import AviaCallsCore

private func w(_ start: Double, _ text: String, len: Double = 0.4) -> Word { Word(start: start, end: start + len, text: text) }
private func ev(_ t: Double, _ e: TimelineEvent) -> TimedEvent { TimedEvent(t: t, event: e) }
private func run(mic: [Word] = [], zoom: [Word] = [], _ timeline: [TimedEvent]) -> [Utterance] {
    Attributor.attribute(mic: mic, zoom: zoom, timeline: timeline, myName: "Ivan")
}

@Suite struct AttributorTests {
    @Test func singleUnmutedRemoteIsExact() {
        let u = run(zoom: [w(5, "Hello"), w(5.5, "everyone")], [ev(0, .joined("Bob")), ev(0, .mic(name: "Bob", on: true)), ev(0, .joined("Ann")), ev(0, .mic(name: "Ann", on: false))])
        #expect(u == [Utterance(start: 5, speaker: "Bob", text: "Hello everyone")])
    }

    @Test func myWordsDroppedWhileMuted() {
        let u = run(mic: [w(1, "слышно"), w(11, "привет")], [ev(0, .myMic(on: false)), ev(10, .myMic(on: true))])
        #expect(u == [Utterance(start: 11, speaker: "Ivan", text: "привет")])
    }

    @Test func myWordsKeptWhenMicStateNeverRead() {
        #expect(run(mic: [w(1, "привет")], []) == [Utterance(start: 1, speaker: "Ivan", text: "привет")])
    }

    @Test func severalUnmutedGiveAmbiguousLabel() {
        let u = run(zoom: [w(5, "да")], [ev(0, .mic(name: "Bob", on: true)), ev(0, .mic(name: "Ann", on: true))])
        #expect(u == [Utterance(start: 5, speaker: "Ann / Bob", text: "да")])
    }

    @Test func speakerKeepsPhraseWhenAnotherMicTurnsOn() {
        let u = run(zoom: [w(5, "я"), w(5.5, "думаю"), w(6.0, "что"), w(6.5, "да")],
                    [ev(0, .mic(name: "Bob", on: true)), ev(0, .mic(name: "Ann", on: false)), ev(6.2, .mic(name: "Ann", on: true))])
        #expect(u == [Utterance(start: 5, speaker: "Bob", text: "я думаю что да")])
    }

    @Test func ambiguityReturnsAfterPause() {
        let u = run(zoom: [w(5, "раз"), w(9, "два")],
                    [ev(0, .mic(name: "Bob", on: true)), ev(6, .mic(name: "Ann", on: true))])
        #expect(u == [Utterance(start: 5, speaker: "Bob", text: "раз"), Utterance(start: 9, speaker: "Ann / Bob", text: "два")])
    }

    @Test func nobodyUnmutedIsUnknown() {
        let u = run(zoom: [w(5, "алло")], [ev(0, .mic(name: "Bob", on: false))])
        #expect(u == [Utterance(start: 5, speaker: Attributor.unknownSpeaker, text: "алло")])
    }

    @Test func unmuteSeenSlightlyLateStillCounts() {
        let u = run(zoom: [w(9.7, "привет", len: 0.2)], [ev(0, .mic(name: "Bob", on: false)), ev(10.0, .mic(name: "Bob", on: true))])
        #expect(u.map(\.speaker) == ["Bob"])
    }

    @Test func iAmNotACandidateOnZoomTrack() {
        let u = run(zoom: [w(5, "hi")], [ev(0, .mic(name: "Ivan", on: true)), ev(0, .mic(name: "Bob", on: true))])
        #expect(u.map(\.speaker) == ["Bob"])
    }

    @Test func unknownStateUsedOnlyWhenNobodyIsOn() {
        let onlyUnknown = run(zoom: [w(5, "hi")], [ev(0, .mic(name: "Bob", on: nil)), ev(0, .mic(name: "Ann", on: false))])
        #expect(onlyUnknown.map(\.speaker) == ["Bob?"])
        let withOn = run(zoom: [w(5, "hi")], [ev(0, .mic(name: "Bob", on: nil)), ev(0, .mic(name: "Ann", on: true))])
        #expect(withOn.map(\.speaker) == ["Ann"])
    }

    @Test func leftParticipantIsNotACandidate() {
        let u = run(zoom: [w(5, "hi")], [ev(0, .mic(name: "Bob", on: true)), ev(0, .mic(name: "Ann", on: true)), ev(2, .left("Ann"))])
        #expect(u.map(\.speaker) == ["Bob"])
    }

    @Test func pauseSplitsUtterancesAndTracksInterleave() {
        let u = run(mic: [w(3, "вопрос")], zoom: [w(1, "раз"), w(6, "два")], [ev(0, .mic(name: "Bob", on: true))])
        #expect(u == [
            Utterance(start: 1, speaker: "Bob", text: "раз"),
            Utterance(start: 3, speaker: "Ivan", text: "вопрос"),
            Utterance(start: 6, speaker: "Bob", text: "два"),
        ])
    }

    @Test func emptyInputGivesEmptyTranscript() {
        #expect(run([]).isEmpty)
    }
}

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

    @Test func infersMeFromMicChangesThatFollowMyMenuState() {
        let timeline = [ev(0, .myMic(on: false)), ev(0, .mic(name: "Ivan", on: false)), ev(0, .mic(name: "Bob", on: false)),
                        ev(148.5, .mic(name: "Ivan", on: true)), ev(149.1, .myMic(on: true)),
                        ev(157.2, .mic(name: "Ivan", on: false)), ev(157.5, .myMic(on: false)),
                        ev(160.8, .mic(name: "Bob", on: true))]
        #expect(Attributor.inferMe(timeline) == "Ivan")
    }

    @Test func doesNotGuessMeWhenSeveralPeopleToggledTogether() {
        let timeline = [ev(0, .myMic(on: false)), ev(0, .mic(name: "Ivan", on: false)), ev(0, .mic(name: "Bob", on: false)),
                        ev(10, .mic(name: "Ivan", on: true)), ev(10.3, .mic(name: "Bob", on: true)), ev(10.5, .myMic(on: true))]
        #expect(Attributor.inferMe(timeline) == nil)
        #expect(Attributor.inferMe([]) == nil)
    }

    @Test func hyphenatedWordPartsAreGluedBack() {
        // Whisper отдаёт «что-то» двумя словами: «что» и «-то»
        #expect(run(mic: [w(1, "что"), w(1.4, "-то"), w(1.8, "вслух")], []).map(\.text) == ["что-то вслух"])
    }

    @Test func activeSpeakerDecidesBetweenSeveralUnmuted() {
        let u = run(zoom: [w(5, "раз"), w(5.5, "два"), w(12, "три")],
                    [ev(0, .mic(name: "Ann", on: true)), ev(0, .mic(name: "Bob", on: true)), ev(1, .speaker("Bob")), ev(11, .speaker("Ann"))])
        #expect(u == [Utterance(start: 5, speaker: "Bob", text: "раз два"), Utterance(start: 12, speaker: "Ann", text: "три")])
    }

    @Test func activeSpeakerMarkIsSeenSlightlyLate() {
        // Zoom переключает метку говорящего примерно через секунду после начала речи
        let u = run(zoom: [w(10.0, "привет")], [ev(0, .mic(name: "Ann", on: true)), ev(0, .mic(name: "Bob", on: true)), ev(1, .speaker("Ann")), ev(10.6, .speaker("Bob"))])
        #expect(u.map(\.speaker) == ["Bob"])
    }

    @Test func mutedActiveSpeakerIsIgnored() {
        // метка говорящего ещё висит на человеке, который уже выключил микрофон
        let u = run(zoom: [w(5, "да")], [ev(0, .mic(name: "Ann", on: false)), ev(0, .mic(name: "Bob", on: true)), ev(0, .mic(name: "Cid", on: true)), ev(1, .speaker("Ann"))])
        #expect(u.map(\.speaker) == ["Bob / Cid"])
    }

    @Test func onlyUnmutedParticipantBeatsStaleSpeakerMark() {
        let u = run(zoom: [w(5, "да")], [ev(0, .mic(name: "Ann", on: false)), ev(0, .mic(name: "Bob", on: true)), ev(1, .speaker("Ann"))])
        #expect(u.map(\.speaker) == ["Bob"])
    }

    @Test func activeSpeakerMarkOnMeDoesNotLabelZoomTrack() {
        let u = run(zoom: [w(5, "да")], [ev(0, .mic(name: "Ann", on: true)), ev(0, .mic(name: "Bob", on: true)), ev(1, .speaker("Ivan"))])
        #expect(u.map(\.speaker) == ["Ann / Bob"])
    }

    @Test func activeSpeakerWorksWhenMicStatesWereNotRead() {
        #expect(run(zoom: [w(5, "да")], [ev(1, .speaker("Ann"))]).map(\.speaker) == ["Ann"])
    }

    @Test func longMonologueIsSplitAtSentenceEnds() {
        // 70 секунд речи без пауз, точка после каждого десятого слова
        let words = (0..<70).map { w(Double($0), $0 % 10 == 9 ? "да." : "да", len: 0.8) }
        let u = run(mic: words, [])
        #expect(u.map(\.start) == [0, 30, 60])
        #expect(u.allSatisfy { $0.speaker == "Ivan" })
        #expect(u[0].text.hasSuffix("да."))
    }

    @Test func emptyInputGivesEmptyTranscript() {
        #expect(run([]).isEmpty)
    }
}

import Foundation
import Testing
@testable import AviaCallsCore

struct MicrophoneMuteIntervalsTests {
    @Test func firstMuteMasksBeginningButFirstUnmutePreservesUnknownBeginning() {
        #expect(intervals([event(3, false), event(5, true)]) == [range(0, 5)])
        #expect(intervals([event(3, true), event(5, false)]) == [range(5, 10)])
        #expect(intervals([event(3, false)]) == [range(0, 10)])
        #expect(intervals([event(3, true)]).isEmpty)
    }

    @Test func usesTrackOffsetAndActualUnmuteTimeWithoutLead() {
        let result = intervals([event(0, true), event(4, false), event(8, true)], offset: 2)
        #expect(result == [range(2, 6)])
        #expect(result.first?.end != 6 - Attributor.unmuteLead)
    }

    @Test func sortsEventsAndPreservesOrderForEqualTimestamps() {
        let unsorted = [event(8, true), event(4, false), event(0, true), event(6, false)]
        #expect(intervals(unsorted) == [range(4, 8)])
        #expect(intervals([event(5, false), event(5, true)]) == [range(0, 5)])
        #expect(intervals([event(5, true), event(5, false)]) == [range(5, 10)])
    }

    @Test func clipsBeforeAndAfterAudioAndUsesPriorState() {
        #expect(intervals([event(0, false), event(3, true)], offset: 5).isEmpty)
        #expect(intervals([event(0, true), event(3, false), event(8, true)], offset: 5) == [range(0, 3)])
        #expect(intervals([event(0, true), event(3, false), event(40, true)], offset: 5) == [range(0, 10)])
        #expect(intervals([event(0, true), event(40, false)]).isEmpty)
    }

    @Test func ignoresOtherParticipantsAndUnknownState() {
        let others = [
            TimedEvent(t: 0, event: .mic(name: "Я", on: false)),
            TimedEvent(t: 2, event: .mic(name: "Коллега", on: false)),
            TimedEvent(t: 3, event: .me("Я")),
            TimedEvent(t: 4, event: .speaker("Я")),
            TimedEvent(t: 5, event: .mic(name: "Я", on: nil))
        ]
        #expect(intervals(others).isEmpty)
        #expect(intervals(others + [event(6, false), event(8, true)]) == [range(0, 8)])
    }

    @Test func repeatedStatesDoNotReopenOrShortenRanges() {
        #expect(intervals([event(0, true), event(1, true), event(2, false), event(4, false), event(6, true), event(7, true)]) == [range(2, 6)])
        #expect(intervals([event(0, true), event(2, false), event(5, true), event(5, false), event(8, true)]) == [range(2, 8)])
    }

    @Test func rejectsNonFiniteInputsAndIgnoresCorruptEvents() {
        #expect(intervals([event(0, false)], duration: 0).isEmpty)
        #expect(intervals([event(0, false)], duration: -1).isEmpty)
        #expect(intervals([event(0, false)], duration: .infinity).isEmpty)
        #expect(intervals([event(0, false)], offset: .nan).isEmpty)
        #expect(intervals([event(.nan, false), event(.infinity, false), event(0, true), event(5, false)]) == [range(5, 10)])
    }

    @Test func intervalRoundTripsForCheckpointIdentity() throws {
        let expected = [range(0, 3), range(7, 10)]
        let data = try JSONEncoder().encode(expected)
        #expect(try JSONDecoder().decode([MicrophoneMuteInterval].self, from: data) == expected)
    }

    private func event(_ time: Double, _ on: Bool) -> TimedEvent { TimedEvent(t: time, event: .myMic(on: on)) }
    private func range(_ start: Double, _ end: Double) -> MicrophoneMuteInterval { .init(start: start, end: end) }
    private func intervals(_ timeline: [TimedEvent], offset: Double = 0, duration: Double = 10) -> [MicrophoneMuteInterval] {
        MicrophoneMuteIntervals.intervals(timeline: timeline, offset: offset, duration: duration)
    }
}

import Testing
@testable import AviaCallsCore

private func snap(_ ps: [(String, Bool?)], title: String? = nil, listOpen: Bool = false, myMic: Bool? = nil, me: String? = nil) -> ZoomSnapshot {
    ZoomSnapshot(title: title, participants: ps.map { Participant(name: $0.0, micOn: $0.1, isMe: $0.0 == me) }, listOpen: listOpen, myMicOn: myMic)
}

@Suite struct TimelineBuilderTests {
    @Test func firstSnapshotEmitsEverything() {
        var b = TimelineBuilder(myName: nil)
        let ev = b.ingest(snap([("Ivan", true), ("Bob", false)], title: "Sync", myMic: true, me: "Ivan"), at: 1)
        #expect(ev.map(\.event) == [
            .title("Sync"), .myMic(on: true), .me("Ivan"),
            .joined("Ivan"), .mic(name: "Ivan", on: true),
            .joined("Bob"), .mic(name: "Bob", on: false),
        ])
        #expect(ev.allSatisfy { $0.t == 1 })
        #expect(b.myName == "Ivan")
    }

    @Test func unchangedSnapshotEmitsNothing() {
        var b = TimelineBuilder(myName: nil)
        _ = b.ingest(snap([("Bob", false)]), at: 1)
        #expect(b.ingest(snap([("Bob", false)]), at: 2).isEmpty)
    }

    @Test func micChangeEmitsOneEvent() {
        var b = TimelineBuilder(myName: nil)
        _ = b.ingest(snap([("Bob", false)]), at: 1)
        #expect(b.ingest(snap([("Bob", true)]), at: 2) == [TimedEvent(t: 2, event: .mic(name: "Bob", on: true))])
    }

    @Test func titleMayArriveLater() {
        var b = TimelineBuilder(myName: nil)
        _ = b.ingest(snap([("Bob", false)]), at: 1)
        #expect(b.ingest(snap([("Bob", false)], title: "Sync"), at: 2).map(\.event) == [.title("Sync")])
        // панель кнопок скрылась, название пропало — это не событие
        #expect(b.ingest(snap([("Bob", false)]), at: 3).isEmpty)
    }

    @Test func offscreenWithClosedPanelBecomesUnknownNotLeft() {
        var b = TimelineBuilder(myName: nil)
        _ = b.ingest(snap([("Ann", true), ("Bob", true)]), at: 0)
        #expect(b.ingest(snap([("Ann", true)]), at: 3).isEmpty)          // ещё рано
        #expect(b.ingest(snap([("Ann", true)]), at: 6).map(\.event) == [.mic(name: "Bob", on: nil)])
        #expect(b.ingest(snap([("Ann", true)]), at: 9).isEmpty)          // повторно не шлём
        #expect(b.ingest(snap([("Ann", true), ("Bob", false)]), at: 10).map(\.event) == [.mic(name: "Bob", on: false)])
    }

    @Test func missingFromOpenListMeansLeft() {
        var b = TimelineBuilder(myName: nil)
        _ = b.ingest(snap([("Ann", true), ("Bob", true)], listOpen: true), at: 0)
        #expect(b.ingest(snap([("Ann", true)], listOpen: true), at: 6).map(\.event) == [.left("Bob")])
        #expect(b.ingest(snap([("Ann", true), ("Bob", false)], listOpen: true), at: 7).map(\.event) == [.joined("Bob"), .mic(name: "Bob", on: false)])
    }

    @Test func unreadMicKeepsLastKnownState() {
        var b = TimelineBuilder(myName: nil)
        _ = b.ingest(snap([("Bob", true)]), at: 0)
        #expect(b.ingest(snap([("Bob", nil)]), at: 1).isEmpty)
    }

    @Test func rememberedNameSurvivesClosedPanel() {
        var b = TimelineBuilder(myName: "Ivan")
        #expect(b.ingest(snap([("Ivan", true)]), at: 0).map(\.event) == [.joined("Ivan"), .mic(name: "Ivan", on: true)])
        #expect(b.myName == "Ivan")
    }
}

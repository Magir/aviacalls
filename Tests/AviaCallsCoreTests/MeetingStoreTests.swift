import Foundation
import Testing
@testable import AviaCallsCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-\(UUID().uuidString)")
}
private let start = Date(timeIntervalSince1970: 1_790_000_000)

@Suite struct MeetingStoreTests {
    @Test func timelineAppendsAndLoads() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        try store.append([TimedEvent(t: 1, event: .joined("Bob"))])
        try store.append([TimedEvent(t: 2, event: .mic(name: "Bob", on: nil)), TimedEvent(t: 3, event: .title("Sync"))])
        #expect(try store.loadTimeline().map(\.event) == [.joined("Bob"), .mic(name: "Bob", on: nil), .title("Sync")])
    }

    @Test func missingTimelineIsEmpty() throws {
        #expect(try MeetingStore(root: tempRoot(), start: start).loadTimeline().isEmpty)
    }

    @Test func infoAndWordsRoundTrip() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        let info = MeetingInfo(title: "Sync", start: start, end: nil, participants: ["Bob"], myName: "Ivan", namesRead: true, micOffset: 0.1, zoomOffset: 0.2)
        try store.save(info: info)
        #expect(try store.loadInfo() == info)
        let words = TrackWords(mic: [Word(start: 1, end: 2, text: "да")], zoom: [])
        #expect(store.loadWords() == nil)
        try store.save(words: words)
        #expect(store.loadWords() == words)
    }

    @Test func screenshotsRoundTrip() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        #expect(store.loadScreenshots().isEmpty)
        let shots = [Screenshot(time: 12.5, path: "screens/00-00-12.jpg")]
        try store.save(screenshots: shots)
        #expect(store.loadScreenshots() == shots)
    }

    @Test func legacyMeetingsDoNotOptIntoCloudProcessing() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        var info = MeetingInfo(title: "Sync", start: start, end: nil, participants: [], myName: nil,
                               namesRead: false, micOffset: 0, zoomOffset: 0)
        try store.save(info: info)
        #expect(try store.loadInfo().glossaryPostprocessing == nil)
        info.glossaryPostprocessing = true
        try store.save(info: info)
        #expect(try store.loadInfo().glossaryPostprocessing == true)
    }

    @Test func accumulatesKnownPostprocessingCostsAndMarksUnknownRequests() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        try store.updatePostprocessingCost { $0.add(0.000123) }
        try store.updatePostprocessingCost { $0.add(0) }
        #expect(store.loadPostprocessingCost() == .init(amount: 0.000123, isLowerBound: false))
        try store.updatePostprocessingCost { $0.add(nil) }
        #expect(store.loadPostprocessingCost() == .init(amount: 0.000123, isLowerBound: true))
        #expect(PostprocessingCost(amount: 0, isLowerBound: true).label == "Стоимость недоступна")
        #expect(PostprocessingCost(amount: 0.019, isLowerBound: true).label == "Потрачено не менее $0.0190")
    }

    /// Recorder и Pipeline держат свою копию MeetingInfo и сохраняют её целиком: стоимость при этом не теряется.
    @Test func savingMeetingInfoKeepsPostprocessingCost() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        let info = MeetingInfo(title: "Sync", start: start, end: nil, participants: [], myName: nil,
                               namesRead: false, micOffset: 0, zoomOffset: 0)
        try store.save(info: info)
        try store.updatePostprocessingCost { $0.add(0.25) }
        try store.save(info: info)
        #expect(store.loadPostprocessingCost() == .init(amount: 0.25, isLowerBound: false))
    }

    @Test func pendingPostprocessingRequestSurvivesRestartAndKnownCostClosesIt() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        try store.updatePostprocessingCost { $0.beginRequest() }
        #expect(store.loadPostprocessingCost()?.isLowerBound == true)
        let restarted = MeetingStore(existing: store.dir)
        try restarted.updatePostprocessingCost { $0.add(0.25) }
        #expect(restarted.loadPostprocessingCost() == .init(amount: 0.25, isLowerBound: false))
    }

    @Test func olderPendingRequestRemainsUnknownAfterNewKnownCost() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        try store.updatePostprocessingCost { $0.beginRequest() }
        try store.updatePostprocessingCost { $0.beginRequest() }
        try store.updatePostprocessingCost { $0.add(0.25) }
        #expect(store.loadPostprocessingCost() == .init(amount: 0.25, isLowerBound: true))
    }

    @Test func finalizeRenamesFolderWithSafeTitle() throws {
        let root = tempRoot()
        let store = try MeetingStore(root: root, start: start)
        let stamp = store.dir.lastPathComponent
        try store.save(transcript: "x")
        let dir = try store.finalize(title: "Sync: план/факт")
        #expect(dir.lastPathComponent == "\(stamp) Sync- план-факт")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
        #expect(store.dir == dir)
    }

    @Test func finalizeWithoutTitleKeepsFolder() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        let before = store.dir
        #expect(try store.finalize(title: nil) == before)
        #expect(try store.finalize(title: "  ") == before)
    }

    @Test func secondMeetingInSameMinuteGetsOwnFolder() throws {
        let root = tempRoot()
        let a = try MeetingStore(root: root, start: start)
        let b = try MeetingStore(root: root, start: start)
        #expect(a.dir != b.dir)
    }

    @Test func audioURLPrefersCafThenM4a() throws {
        let store = try MeetingStore(root: tempRoot(), start: start)
        #expect(store.audioURL("mic").pathExtension == "caf")
        try Data().write(to: store.dir.appendingPathComponent("mic.m4a"))
        #expect(store.audioURL("mic").pathExtension == "m4a")
        try Data().write(to: store.dir.appendingPathComponent("mic.caf"))
        #expect(store.audioURL("mic").pathExtension == "caf")
    }
}

import Foundation
import Testing
@testable import AviaCallsCore

struct TranscriptionModeTests {
    @Test func oldMeetingDoesNotOptIntoCloud() throws {
        let old = Data(#"{"title":"Старая встреча","start":0,"participants":[],"namesRead":false,"micOffset":0,"zoomOffset":0}"#.utf8)
        let info = try JSONDecoder().decode(MeetingInfo.self, from: old)
        #expect(info.transcriptionMode == nil)
    }

    @Test func storesModeAndSeparateTranscriptionCost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root, start: Date())
        let info = MeetingInfo(title: nil, start: Date(), end: nil, participants: [], myName: nil,
                               namesRead: false, micOffset: 0, zoomOffset: 0, transcriptionMode: .openRouter)
        try store.save(info: info)
        #expect(try store.loadInfo().transcriptionMode == .openRouter)
        #expect(store.loadTranscriptionCost() == nil)
        try store.updatePostprocessingCost { $0.add(0.3) }
        try store.updateTranscriptionCost { $0.add(0.1) }
        try store.updateTranscriptionCost { $0.beginRequest() }
        #expect(store.loadTranscriptionCost()?.amount == 0.1)
        #expect(store.loadTranscriptionCost()?.isLowerBound == true)
        #expect(store.loadPostprocessingCost() == PostprocessingCost(amount: 0.3))
        try store.updateTranscriptionCost { $0.add(0.2) }
        let amount = try #require(store.loadTranscriptionCost()?.amount)
        #expect(abs(amount - 0.3) < 0.000001)
        #expect(store.loadTranscriptionCost()?.isLowerBound == false)
        #expect(FileManager.default.fileExists(atPath: store.dir.appendingPathComponent("transcription-cost.json").path))
    }
}

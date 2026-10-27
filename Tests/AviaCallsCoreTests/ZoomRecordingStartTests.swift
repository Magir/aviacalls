import Foundation
import Testing
@testable import AviaCallsCore

private func canStart(_ window: AXNode, menu: String? = nil) -> Bool {
    ZoomTreeParser.canStartRecording(window: window,
        snapshot: ZoomTreeParser.parse(window: window, muteMenuTitle: menu))
}

@Suite struct ZoomRecordingStartTests {
    @Test func emptyMeetingWindowDoesNotStartRecording() {
        #expect(!canStart(window([])))
        #expect(!canStart(AXNode(role: "?")))
        #expect(!canStart(window([AXNode(role: "AXGroup", children: [AXNode(role: "?")])])))
    }

    @Test(arguments: ["Включить звук", "Выключить звук", "Mute Audio", "Unmute Audio"])
    func applicationMenuDoesNotConfirmMeeting(menu: String) {
        #expect(!canStart(window([]), menu: menu))
    }

    @Test func titleAloneDoesNotConfirmMeeting() {
        let node = window([AXNode(role: "AXButton", identifier: "MeetingTopBarInfoButton", description: "Zoom Meeting")])
        #expect(!canStart(node, menu: "Выключить звук"))
    }

    @Test func participantConfirmsMeetingWithoutToolbarOrTitle() {
        #expect(canStart(window([tile("Ivan Testov, Звук компьютера выключен, Video off")])))
        #expect(canStart(window([row("Ivan Testov (Гость)")])))
    }

    @Test func emptyParticipantNameDoesNotConfirmMeeting() {
        #expect(!canStart(window([tile(", Computer audio muted, Video off")])))
        #expect(!canStart(window([row("   ")])))
    }

    @Test func leaveButtonConfirmsMeetingWithoutReadableParticipants() {
        #expect(canStart(window([AXNode(role: "AXGroup", children: [AXNode(role: "AXButton", identifier: "leave")])])))
        #expect(!canStart(window([AXNode(role: "AXStaticText", identifier: "leave")])))
        #expect(!canStart(window([AXNode(role: "AXButton", identifier: "cancel", description: "Завершить")])))
    }

    @Test(arguments: ["zoom floating video", "zoom share"])
    func emptySharingWindowDoesNotStartRecording(title: String) {
        #expect(!canStart(AXNode(role: "AXWindow", title: title)))
    }

    @Test(arguments: ["host-panel-open", "host-panel-closed", "host-both-unmuted", "guest-panel-open"])
    func recordedMeetingsStartRecording(name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode(ZoomRawSnapshot.self, from: Data(contentsOf: url))
        #expect(canStart(raw.window, menu: raw.muteMenuTitle))
    }
}

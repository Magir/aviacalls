import Foundation
import Testing
@testable import AviaCallsCore

private func canStart(_ window: AXNode, menu: String? = nil) -> Bool {
    ZoomTreeParser.parse(window: window, muteMenuTitle: menu).inMeeting
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

    /// Пустое имя не должно попасть в участники и во время записи: из него вышли бы пустой спикер и namesRead.
    @Test func blankNamesAreDropped() {
        let s = parse([tile(", Computer audio muted, Video off"), row("   "), tile("Ivan Testov, Звук компьютера выключен, Video off")])
        #expect(s.participants.map(\.name) == ["Ivan Testov"])
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
        let raw = try loadRaw(name)
        #expect(canStart(raw.window, menu: raw.muteMenuTitle))
    }
}

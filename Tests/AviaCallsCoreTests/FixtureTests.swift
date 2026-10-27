import Foundation
import Testing
@testable import AviaCallsCore

// Снимки живого Zoom 7.0.6 (2026-10-01): мак «Ivan Testov» (имя заменено), телефон «Tester».
private func load(_ name: String) throws -> ZoomSnapshot {
    let raw = try loadRaw(name)
    return ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle)
}

private func mics(_ s: ZoomSnapshot) -> [String: Bool?] { Dictionary(uniqueKeysWithValues: s.participants.map { ($0.name, $0.micOn) }) }

@Suite struct FixtureTests {
    @Test func hostPanelClosed() throws {
        let s = try load("host-panel-closed")
        #expect(mics(s) == ["Ivan Testov": false, "Tester": false])
        #expect(!s.listOpen)
        #expect(s.myMicOn == false)
    }

    @Test func hostBothUnmuted() throws {
        let s = try load("host-both-unmuted")
        #expect(mics(s) == ["Ivan Testov": true, "Tester": true])
        #expect(s.myMicOn == true)
        #expect(s.title == "Zoom Meeting Ivan Testov")
    }

    @Test func hostPanelOpen() throws {
        let s = try load("host-panel-open")
        #expect(mics(s) == ["Ivan Testov": false, "Tester": false])
        #expect(s.listOpen)
        #expect(s.participants.filter(\.isMe).map(\.name) == ["Ivan Testov"])
    }

    @Test func guestPanelOpen() throws {
        let s = try load("guest-panel-open")
        #expect(mics(s) == ["Ivan Testov": false, "Tester": false])
        #expect(s.participants.filter(\.isMe).map(\.name) == ["Ivan Testov"])
    }

    /// Строки списка без плиток: у гостя микрофоны других участников показаны картинками, а не кнопками.
    @Test(arguments: ["host-panel-open", "guest-panel-open"])
    func listAloneGivesSameResult(name: String) throws {
        var raw = try loadRaw(name)
        func dropTiles(_ n: AXNode) -> AXNode {
            var n = n
            n.children = n.children.filter { $0.role != "AXTabGroup" }.map(dropTiles)
            return n
        }
        raw.window = dropTiles(raw.window)
        let s = ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle)
        #expect(mics(s) == ["Ivan Testov": false, "Tester": false])
    }
}

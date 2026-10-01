import Foundation
import Testing
@testable import AviaCallsCore

// Снимки живого Zoom 7.0.6 (2026-10-01): мак «Ivan Boitsov», телефон «Tester».
private func load(_ name: String) throws -> ZoomSnapshot {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let raw = try JSONDecoder().decode(ZoomRawSnapshot.self, from: Data(contentsOf: url))
    return ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle)
}

private func mics(_ s: ZoomSnapshot) -> [String: Bool?] { Dictionary(uniqueKeysWithValues: s.participants.map { ($0.name, $0.micOn) }) }

@Suite struct FixtureTests {
    @Test func hostPanelClosed() throws {
        let s = try load("host-panel-closed")
        #expect(mics(s) == ["Ivan Boitsov": false, "Tester": false])
        #expect(!s.listOpen)
        #expect(s.myMicOn == false)
    }

    @Test func hostBothUnmuted() throws {
        let s = try load("host-both-unmuted")
        #expect(mics(s) == ["Ivan Boitsov": true, "Tester": true])
        #expect(s.myMicOn == true)
        #expect(s.title == "Zoom Meeting Ivan Boitsov")
    }

    @Test func hostPanelOpen() throws {
        let s = try load("host-panel-open")
        #expect(mics(s) == ["Ivan Boitsov": false, "Tester": false])
        #expect(s.listOpen)
        #expect(s.participants.filter(\.isMe).map(\.name) == ["Ivan Boitsov"])
    }

    @Test func guestPanelOpen() throws {
        let s = try load("guest-panel-open")
        #expect(mics(s) == ["Ivan Boitsov": false, "Tester": false])
        #expect(s.participants.filter(\.isMe).map(\.name) == ["Ivan Boitsov"])
    }

    /// Строки списка без плиток: у гостя микрофоны других участников показаны картинками, а не кнопками.
    @Test(arguments: ["host-panel-open", "guest-panel-open"])
    func listAloneGivesSameResult(name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        var raw = try JSONDecoder().decode(ZoomRawSnapshot.self, from: Data(contentsOf: url))
        func dropTiles(_ n: AXNode) -> AXNode {
            var n = n
            n.children = n.children.filter { $0.role != "AXTabGroup" }.map(dropTiles)
            return n
        }
        raw.window = dropTiles(raw.window)
        let s = ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle)
        #expect(mics(s) == ["Ivan Boitsov": false, "Tester": false])
    }
}

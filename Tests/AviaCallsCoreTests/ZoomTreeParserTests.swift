import Testing
@testable import AviaCallsCore

func tile(_ d: String) -> AXNode { AXNode(role: "AXTabGroup", description: d) }
func row(_ text: String, buttons: [String] = []) -> AXNode {
    AXNode(role: "AXRow", children: [AXNode(role: "AXCell", identifier: "ZMHCTableItemType_PANELIST",
        children: [AXNode(role: "AXStaticText", value: text)] + buttons.map { AXNode(role: "AXButton", description: $0) })])
}
func window(_ kids: [AXNode]) -> AXNode { AXNode(role: "AXWindow", identifier: "zm.meeting.window.main", children: kids) }
func parse(_ kids: [AXNode], menu: String? = nil) -> ZoomSnapshot { ZoomTreeParser.parse(window: window(kids), muteMenuTitle: menu) }

@Suite struct ZoomTreeParserTests {
    @Test func mergesTilesAndList() {
        let s = parse([
            tile("Ivan Boitsov, Звук компьютера включен, Video off"),
            tile("тест тестов, Звук компьютера выключен, Video on"),
            AXNode(role: "AXScrollArea", children: [AXNode(role: "AXOutline", children: [
                row("Ivan Boitsov (Организатор, я)", buttons: ["Остановить видео", "Выключить звук"]),
                row("тест тестов (Гость)", buttons: ["Попросить включить видео", "Попросить вкл"]),
            ])]),
        ])
        #expect(s.participants == [
            Participant(name: "Ivan Boitsov", micOn: true, isMe: true),
            Participant(name: "тест тестов", micOn: false, isMe: false),
        ])
        #expect(s.listOpen)
    }

    @Test func tilesOnlyWhenPanelClosed() {
        let s = parse([tile("Ivan Boitsov, Звук компьютера включен, Video off")])
        #expect(s.participants == [Participant(name: "Ivan Boitsov", micOn: true, isMe: false)])
        #expect(!s.listOpen)
    }

    @Test func listOnlyTakesMicFromRowButtons() {
        let s = parse([
            row("Ivan Boitsov (Организатор, я)", buttons: ["Начать видео", "Включить звук"]),
            row("тест тестов (Гость)", buttons: ["Попросить включить видео", "Выключить звук"]),
        ])
        #expect(s.participants == [
            Participant(name: "Ivan Boitsov", micOn: false, isMe: true),
            Participant(name: "тест тестов", micOn: true, isMe: false),
        ])
    }

    @Test func englishStrings() {
        let s = parse([
            tile("John Doe, Computer audio unmuted, Video off"),
            tile("Jane Roe, Computer audio muted, Video on"),
            row("John Doe (Host, me)", buttons: ["Mute"]),
        ])
        #expect(s.participants == [
            Participant(name: "John Doe", micOn: true, isMe: true),
            Participant(name: "Jane Roe", micOn: false, isMe: false),
        ])
    }

    @Test func nameWithComma() {
        let s = parse([tile("Doe, John, Звук компьютера выключен, Video off")])
        #expect(s.participants.map(\.name) == ["Doe, John"])
    }

    @Test func nameWithParentheses() {
        let both = parse([tile("Anna (Aviasales), Звук компьютера включен, Video off"), row("Anna (Aviasales) (Гость)")])
        #expect(both.participants == [Participant(name: "Anna (Aviasales)", micOn: true, isMe: false)])
        let listOnly = parse([row("Anna (Aviasales)"), row("Bob (Aviasales) (Гость)")])
        #expect(listOnly.participants.map(\.name) == ["Anna (Aviasales)", "Bob (Aviasales)"])
    }

    @Test func extraTileFieldsAfterVideo() {
        let s = parse([tile("Ivan Boitsov, Звук компьютера включен, Video off, закреплено")])
        #expect(s.participants == [Participant(name: "Ivan Boitsov", micOn: true, isMe: false)])
    }

    @Test func namesakesCountAsOne() {
        let s = parse([tile("Ivan Boitsov, Звук компьютера выключен, Video off"), tile("Ivan Boitsov, Звук компьютера включен, Video off")])
        #expect(s.participants == [Participant(name: "Ivan Boitsov", micOn: true, isMe: false)])
    }

    @Test func titleAndMyMic() {
        let s = parse([AXNode(role: "AXButton", identifier: "MeetingTopBarInfoButton", description: "Zoom Meeting Ivan Boitsov")], menu: "Выключить звук")
        #expect(s.title == "Zoom Meeting Ivan Boitsov")
        #expect(s.myMicOn == true)
        #expect(parse([], menu: "Включить звук").myMicOn == false)
        #expect(parse([], menu: "Unmute Audio").myMicOn == false)
        #expect(parse([], menu: "Mute Audio").myMicOn == true)
    }

    @Test func hiddenToolbarGivesNoTitleButKeepsParticipants() {
        let s = parse([tile("Ivan Boitsov, Звук компьютера включен, Video off")])
        #expect(s.title == nil)
        #expect(s.myMicOn == nil)
        #expect(s.participants.count == 1)
    }

    @Test func readsActiveSpeakerFromTile() {
        // так Zoom 7.0.6 помечает говорящего на встрече от трёх человек (в русском интерфейсе метка тоже английская)
        let s = parse([
            tile("Ann, Звук компьютера включен, Video on"),
            tile("Bob, Звук компьютера включен, Video on, active speaker"),
        ])
        #expect(s.activeSpeaker == "Bob")
        #expect(s.participants.map(\.name) == ["Ann", "Bob"])
        #expect(parse([tile("Ann, Звук компьютера включен, Video on")]).activeSpeaker == nil)
    }

    @Test func foreignTabGroupIsIgnored() {
        let s = parse([AXNode(role: "AXTabGroup", description: "Настройки", children: [tile("Ivan Boitsov, Звук компьютера включен, Video off")])])
        #expect(s.participants.map(\.name) == ["Ivan Boitsov"])
    }
}

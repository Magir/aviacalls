# AviaCalls, этап 1 — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** приложение в менюбаре macOS, которое само записывает встречу в штатном Zoom и после неё кладёт на диск транскрипт с именами говорящих.

**Architecture:** SwiftPM-пакет из двух целей. `AviaCallsCore` — чистая логика без системных вызовов (разбор дерева Zoom, таймлайн, подпись реплик, хранение), покрыта юнит-тестами. `AviaCalls` — исполняемая цель: чтение Accessibility, захват звука, Whisper, менюбар. Сборка в `.app` скриптом, подпись сертификатом Apple Development, чтобы выданные разрешения не слетали между сборками.

**Tech Stack:** Swift 6.3 (режим языка 5), SwiftUI `MenuBarExtra`, Accessibility API, Core Audio process tap, AVAudioEngine, WhisperKit (large-v3-turbo), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-01-zoom-local-recorder-design.md`

## Global Constraints

- macOS 14.4+ (process tap), проверяем на macOS 26.5 и Zoom 7.0.6.
- Bundle ID Zoom: `us.zoom.xos`; окно встречи: `zm.meeting.window.main`.
- Звук и текст с компьютера не уходят. Единственное обращение в сеть — разовая загрузка модели Whisper.
- Запись идёт на диск по ходу встречи; падение приложения не теряет записанное.
- Угаданное имя без пометки в транскрипт не попадает: неоднозначность пишем как `Имя1 / Имя2`, неизвестное состояние как `Имя?`.
- Папка встреч: `~/Documents/Meetings/<yyyy-MM-dd HH-mm> <название>/`.
- Формат строки транскрипта: `[00:12:43] John Doe: Hello everyone`.
- Коммит и push в `main` после каждой задачи, автор Ivan Boitsov.

## Уточнения к спеке, принятые при планировании

- Во время встречи дорожки пишутся в CAF (16 кГц, моно, int16): он переживает падение и сразу годится для Whisper. В m4a сжимаем после транскрибации.
- Кандидаты в говорящие — участники с включённым микрофоном. Участников с неизвестным состоянием (ушли с экрана при закрытой панели) берём в кандидаты, только если включённых нет.
- Включение микрофона считаем случившимся на 0,4 с раньше, чем мы его увидели (`Attributor.unmuteLead`): опрос идёт раз в 0,3 с, а человек начинает говорить сразу.
- Кто из участников «я», узнаём из списка участников (пометка `я`/`me`) и запоминаем между встречами. Свой микрофон читаем из пункта меню `onMuteAudio:` — он виден всегда, в отличие от панели кнопок.
- Имя говорящего по ходу фразы не меняем: если человек говорил один, а посреди фразы включился второй микрофон, фраза остаётся за первым (`Attributor.continuityGap`).

## Review Focus

1. Смена устройства вывода посреди встречи (подключили AirPods) — запись Zoom продолжается, время в файле не уезжает. Ручная проверка в задаче 7.
2. Имя участника с запятой или скобками (`Doe, John`, `Anna (Aviasales)`) — один участник, имя целиком. Тесты в задаче 1.
3. Панель кнопок Zoom скрылась, название встречи не читается — участники читаются, название приходит позже. Тесты в задачах 1 и 2.
4. Участник ушёл с экрана галереи при закрытой панели — это не `left`, состояние микрофона «неизвестно». Тест в задаче 2.
5. Приложение убили посреди записи — файлы звука открываются, `--transcribe` восстанавливает транскрипт. Ручная проверка в задаче 7.

## Структура файлов

```
Package.swift
Resources/Info.plist
scripts/bundle.sh
Sources/AviaCallsCore/
  Models.swift            AXNode, ZoomRawSnapshot, Participant, ZoomSnapshot, Word, Utterance
  ZoomTreeParser.swift    дерево окна → ZoomSnapshot
  Timeline.swift          TimelineEvent, TimedEvent, TimelineBuilder
  Attributor.swift        слова + таймлайн → реплики
  TranscriptRenderer.swift
  MeetingStore.swift      папка встречи, MeetingInfo, TrackWords
Sources/AviaCalls/
  main.swift              разбор аргументов, запуск приложения
  CLI.swift               --dump-ax, --record-test, --transcribe
  ZoomReader.swift        Accessibility → AXNode
  TrackWriter.swift       буферы → CAF 16 кГц
  ZoomTap.swift           звук процесса Zoom
  MicCapture.swift        микрофон
  AudioCapture.swift      две дорожки вместе
  Transcriber.swift       WhisperKit
  Pipeline.swift          папка встречи → транскрипт
  RecorderController.swift
  AviaCallsApp.swift      менюбар
Tests/AviaCallsCoreTests/
  ZoomTreeParserTests.swift, TimelineBuilderTests.swift, AttributorTests.swift,
  TranscriptRendererTests.swift, MeetingStoreTests.swift, FixtureTests.swift
  Fixtures/*.json
```

---

### Task 1: Пакет, модели, разбор дерева Zoom

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/AviaCallsCore/Models.swift`, `Sources/AviaCallsCore/ZoomTreeParser.swift`, `Sources/AviaCalls/main.swift`
- Test: `Tests/AviaCallsCoreTests/ZoomTreeParserTests.swift`

**Interfaces:**
- Produces: `AXNode`, `ZoomRawSnapshot`, `Participant`, `ZoomSnapshot`, `ZoomTreeParser.parse(window:muteMenuTitle:) -> ZoomSnapshot`

- [ ] **Step 1: каркас пакета**

`Package.swift`:
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AviaCalls",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "AviaCallsCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AviaCalls", dependencies: ["AviaCallsCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AviaCallsCoreTests", dependencies: ["AviaCallsCore"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```
`.gitignore`: `.build/`, `build/`, `.swiftpm/`, `.DS_Store`.
`Sources/AviaCalls/main.swift`: `print("AviaCalls")`.
`Tests/AviaCallsCoreTests/Fixtures/.gitkeep` — пустой.

- [ ] **Step 2: модели**

`Sources/AviaCallsCore/Models.swift`:
```swift
import Foundation

/// Узел дерева Accessibility, снятый с окна Zoom.
public struct AXNode: Codable, Equatable, Sendable {
    public var role: String
    public var roleDescription: String?
    public var identifier: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var children: [AXNode]

    public init(role: String, roleDescription: String? = nil, identifier: String? = nil, title: String? = nil,
                description: String? = nil, value: String? = nil, children: [AXNode] = []) {
        self.role = role; self.roleDescription = roleDescription; self.identifier = identifier
        self.title = title; self.description = description; self.value = value; self.children = children
    }
}

/// Всё, что читаем из Zoom за один опрос. В таком виде лежат фикстуры тестов.
public struct ZoomRawSnapshot: Codable, Equatable, Sendable {
    public var window: AXNode
    public var muteMenuTitle: String?
    public init(window: AXNode, muteMenuTitle: String?) { self.window = window; self.muteMenuTitle = muteMenuTitle }
}

public struct Participant: Codable, Equatable, Sendable {
    public var name: String
    public var micOn: Bool?   // nil — состояние не прочиталось
    public var isMe: Bool
    public init(name: String, micOn: Bool?, isMe: Bool) { self.name = name; self.micOn = micOn; self.isMe = isMe }
}

public struct ZoomSnapshot: Equatable, Sendable {
    public var title: String?
    public var participants: [Participant]
    public var listOpen: Bool    // панель участников открыта — список полный
    public var myMicOn: Bool?
    public init(title: String?, participants: [Participant], listOpen: Bool, myMicOn: Bool?) {
        self.title = title; self.participants = participants; self.listOpen = listOpen; self.myMicOn = myMicOn
    }
}

public struct Word: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct Utterance: Codable, Equatable, Sendable {
    public var start: Double
    public var speaker: String
    public var text: String
    public init(start: Double, speaker: String, text: String) { self.start = start; self.speaker = speaker; self.text = text }
}
```

- [ ] **Step 3: падающие тесты разбора**

`Tests/AviaCallsCoreTests/ZoomTreeParserTests.swift`:
```swift
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

    @Test func foreignTabGroupIsIgnored() {
        let s = parse([AXNode(role: "AXTabGroup", description: "Настройки", children: [tile("Ivan Boitsov, Звук компьютера включен, Video off")])])
        #expect(s.participants.map(\.name) == ["Ivan Boitsov"])
    }
}
```

- [ ] **Step 4: убедиться, что тесты падают**

Run: `swift test --filter ZoomTreeParserTests`
Expected: ошибка компиляции `cannot find 'ZoomTreeParser' in scope`.

- [ ] **Step 5: реализация**

`Sources/AviaCallsCore/ZoomTreeParser.swift`:
```swift
import Foundation

/// Разбирает дерево окна встречи Zoom. Чистая функция: на вход снимок, на выход состояние.
public enum ZoomTreeParser {
    // ponytail: словарь ролей неполный; роль не из словаря останется частью имени.
    // Дополнять по реальным фикстурам (Tests/AviaCallsCoreTests/Fixtures).
    static let knownRoles: Set<String> = ["я", "me", "организатор", "host", "соорганизатор", "co-host", "гость", "guest"]

    public static func parse(window: AXNode, muteMenuTitle: String?) -> ZoomSnapshot {
        var title: String?
        var tiles: [(name: String, mic: Bool?)] = []
        var rows: [(text: String, mic: Bool?)] = []

        func walk(_ n: AXNode) {
            if n.identifier == "MeetingTopBarInfoButton" { title = title ?? n.description; return }
            if n.role == "AXTabGroup", let d = n.description, let t = parseTile(d) { tiles.append(t); return }
            if n.role == "AXRow", let r = parseRow(n) { rows.append(r); return }
            n.children.forEach(walk)
        }
        walk(window)

        var order: [String] = []
        var byName: [String: Participant] = [:]
        for t in tiles {
            if var p = byName[t.name] {
                // тёзок не различить: считаем одним; микрофон включён, если включён хоть у одного
                if t.mic == true { p.micOn = true } else if p.micOn == nil { p.micOn = t.mic }
                byName[t.name] = p
            } else {
                order.append(t.name)
                byName[t.name] = Participant(name: t.name, micOn: t.mic, isMe: false)
            }
        }
        for r in rows {
            // имя с плитки надёжнее: по нему понимаем, где в строке списка кончается имя и начинаются роли
            let tileName = order.filter { r.text == $0 || r.text.hasPrefix($0 + " (") }.max { $0.count < $1.count }
            let name: String, roleList: [String]
            if let tileName {
                name = tileName
                roleList = roles(in: String(r.text.dropFirst(tileName.count)))
            } else {
                (name, roleList) = splitRoles(r.text)
            }
            let isMe = roleList.contains("я") || roleList.contains("me")
            if var p = byName[name] {
                p.isMe = p.isMe || isMe
                p.micOn = p.micOn ?? r.mic
                byName[name] = p
            } else {
                order.append(name)
                byName[name] = Participant(name: name, micOn: r.mic, isMe: isMe)
            }
        }
        return ZoomSnapshot(title: title, participants: order.compactMap { byName[$0] },
                            listOpen: !rows.isEmpty, myMicOn: muteMenuTitle.flatMap(micFromAction))
    }

    /// "Имя, Звук компьютера включен, Video off[, ...]" → имя и микрофон. Имя может содержать запятые.
    static func parseTile(_ d: String) -> (name: String, mic: Bool?)? {
        let parts = d.components(separatedBy: ", ")
        guard let i = parts.indices.dropFirst().first(where: { isAudioPart(parts[$0]) }) else { return nil }
        return (parts[..<i].joined(separator: ", "), micState(parts[i]))
    }

    static func parseRow(_ row: AXNode) -> (text: String, mic: Bool?)? {
        guard let cell = row.children.first(where: { $0.identifier?.hasPrefix("ZMHCTableItemType_") == true }),
              let text = cell.children.first(where: { $0.role == "AXStaticText" })?.value, !text.isEmpty else { return nil }
        let mic = cell.children.filter { $0.role == "AXButton" }.compactMap { $0.description.flatMap(micFromAction) }.first
        return (text, mic)
    }

    /// "Имя (Организатор, я)" → ("Имя", ["организатор", "я"]). Скобки не из словаря ролей считаем частью имени.
    static func splitRoles(_ text: String) -> (String, [String]) {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return (text, []) }
        let found = roles(in: String(text[open.lowerBound...]))
        guard !found.isEmpty, found.allSatisfy(knownRoles.contains) else { return (text, []) }
        return (String(text[..<open.lowerBound]), found)
    }

    static func roles(in suffix: String) -> [String] {
        let t = suffix.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), t.hasSuffix(")") else { return [] }
        return norm(String(t.dropFirst().dropLast())).components(separatedBy: ", ")
    }

    static func isAudioPart(_ s: String) -> Bool {
        let l = norm(s)
        return ["звук", "audio", "телефон", "phone"].contains { l.contains($0) }
    }

    /// Состояние из описания плитки: "Звук компьютера включен" / "Computer audio muted".
    static func micState(_ s: String) -> Bool? {
        let l = norm(s)
        if l.contains("выключен") || (l.contains("muted") && !l.contains("unmuted")) { return false }
        if l.contains("включен") || l.contains("unmuted") { return true }
        return nil
    }

    /// Состояние из названия действия: кнопка "Выключить звук" значит, что микрофон сейчас включён.
    static func micFromAction(_ s: String) -> Bool? {
        let l = norm(s)
        if l.contains("видео") || l.contains("video") { return nil }
        if l.contains("выключить") { return true }
        if l.contains("включить") || l.contains("попросить вкл") || l.contains("unmute") { return false }
        if l.contains("mute") { return true }
        return nil
    }

    static func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "ё", with: "е") }
}
```

- [ ] **Step 6: тесты проходят**

Run: `swift test --filter ZoomTreeParserTests`
Expected: 11 тестов PASS.

- [ ] **Step 7: коммит**

```bash
git add -A && git commit -m "каркас пакета и разбор дерева Zoom" && git push
```

---

### Task 2: Таймлайн

**Files:**
- Create: `Sources/AviaCallsCore/Timeline.swift`
- Test: `Tests/AviaCallsCoreTests/TimelineBuilderTests.swift`

**Interfaces:**
- Consumes: `ZoomSnapshot`, `Participant`
- Produces: `TimelineEvent`, `TimedEvent`, `TimelineBuilder(myName:)`, `ingest(_:at:) -> [TimedEvent]`, `TimelineBuilder.myName`

- [ ] **Step 1: падающие тесты**

`Tests/AviaCallsCoreTests/TimelineBuilderTests.swift`:
```swift
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
```

- [ ] **Step 2: тесты падают**

Run: `swift test --filter TimelineBuilderTests`
Expected: `cannot find 'TimelineBuilder' in scope`.

- [ ] **Step 3: реализация**

`Sources/AviaCallsCore/Timeline.swift`:
```swift
import Foundation

public enum TimelineEvent: Codable, Equatable, Sendable {
    case title(String)
    case joined(String)
    case left(String)
    case mic(name: String, on: Bool?)   // nil — состояние неизвестно
    case myMic(on: Bool)
    case me(String)
}

public struct TimedEvent: Codable, Equatable, Sendable {
    public var t: Double   // секунды от начала записи
    public var event: TimelineEvent
    public init(t: Double, event: TimelineEvent) { self.t = t; self.event = event }
}

/// Превращает поток снимков в события: кто пришёл, ушёл, включил или выключил микрофон.
public struct TimelineBuilder {
    /// Сколько секунд участника нет ни в одном источнике, прежде чем мы на это реагируем.
    public static var goneAfter = 5.0

    public private(set) var myName: String?
    private var title: String?
    private var myMicOn: Bool?
    private var order: [String] = []
    private var present: [String: (mic: Bool?, lastSeen: Double)] = [:]

    public init(myName: String?) { self.myName = myName }

    public mutating func ingest(_ s: ZoomSnapshot, at t: Double) -> [TimedEvent] {
        var out: [TimelineEvent] = []
        if let new = s.title, new != title { title = new; out.append(.title(new)) }
        if let new = s.myMicOn, new != myMicOn { myMicOn = new; out.append(.myMic(on: new)) }
        if let me = s.participants.first(where: \.isMe)?.name, me != myName { myName = me; out.append(.me(me)) }

        for p in s.participants {
            if let cur = present[p.name] {
                let mic = p.micOn ?? cur.mic
                if mic != cur.mic { out.append(.mic(name: p.name, on: mic)) }
                present[p.name] = (mic, t)
            } else {
                order.append(p.name)
                present[p.name] = (p.micOn, t)
                out.append(.joined(p.name))
                out.append(.mic(name: p.name, on: p.micOn))
            }
        }

        let seen = Set(s.participants.map(\.name))
        for name in order where !seen.contains(name) {
            guard let cur = present[name], t - cur.lastSeen > Self.goneAfter else { continue }
            if s.listOpen {
                // список открыт и полон: раз участника там нет, он ушёл
                present[name] = nil
                out.append(.left(name))
            } else if cur.mic != nil {
                // панель закрыта, плитка ушла с экрана: человек, скорее всего, на встрече, но микрофон не видим
                present[name] = (nil, cur.lastSeen)
                out.append(.mic(name: name, on: nil))
            }
        }
        order.removeAll { present[$0] == nil }
        return out.map { TimedEvent(t: t, event: $0) }
    }
}
```

- [ ] **Step 4: тесты проходят**

Run: `swift test --filter TimelineBuilderTests`
Expected: 8 тестов PASS.

- [ ] **Step 5: коммит**

```bash
git add -A && git commit -m "таймлайн: события участников и микрофонов" && git push
```

---

### Task 3: Подпись реплик и рендер транскрипта

**Files:**
- Create: `Sources/AviaCallsCore/Attributor.swift`, `Sources/AviaCallsCore/TranscriptRenderer.swift`
- Test: `Tests/AviaCallsCoreTests/AttributorTests.swift`, `Tests/AviaCallsCoreTests/TranscriptRendererTests.swift`

**Interfaces:**
- Consumes: `Word`, `Utterance`, `TimedEvent`, `TimelineEvent`
- Produces: `Attributor.attribute(mic:zoom:timeline:myName:) -> [Utterance]`, `TranscriptRenderer.render(title:start:participants:utterances:) -> String`

- [ ] **Step 1: падающие тесты**

`Tests/AviaCallsCoreTests/AttributorTests.swift`:
```swift
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

    @Test func emptyInputGivesEmptyTranscript() {
        #expect(run([]).isEmpty)
    }
}
```

`Tests/AviaCallsCoreTests/TranscriptRendererTests.swift`:
```swift
import Foundation
import Testing
@testable import AviaCallsCore

@Suite struct TranscriptRendererTests {
    @Test func rendersHeaderAndLines() {
        let text = TranscriptRenderer.render(
            title: "Sync", start: Date(timeIntervalSince1970: 0), participants: ["John Doe", "Ivan"],
            utterances: [Utterance(start: 763, speaker: "John Doe", text: "Hello everyone"), Utterance(start: 3725, speaker: "Ivan", text: "Привет")])
        #expect(text.hasPrefix("# Sync\n"))
        #expect(text.contains("Участники: John Doe, Ivan"))
        #expect(text.contains("[00:12:43] John Doe: Hello everyone\n"))
        #expect(text.contains("[01:02:05] Ivan: Привет\n"))
    }
}
```

- [ ] **Step 2: тесты падают**

Run: `swift test --filter "AttributorTests|TranscriptRendererTests"`
Expected: `cannot find 'Attributor' in scope`.

- [ ] **Step 3: реализация**

`Sources/AviaCallsCore/Attributor.swift`:
```swift
import Foundation

/// Раздаёт имена словам двух дорожек по таймлайну микрофонов и склеивает слова в реплики.
public enum Attributor {
    /// Включение микрофона считаем случившимся на столько секунд раньше, чем увидели: опрос Zoom идёт с задержкой.
    public static var unmuteLead = 0.4
    /// Пока пауза между словами не длиннее этой, говорящий остаётся прежним, даже если включился ещё чей-то микрофон.
    public static var continuityGap = 1.0
    /// Пауза, после которой начинается новая реплика того же человека.
    public static var maxPause = 2.0
    public static let unknownSpeaker = "Неизвестный"

    private enum Mic { case on, off, unknown }

    private struct Replay {
        let events: [TimedEvent]
        var i = 0
        var mics: [String: Mic] = [:]
        var myMic = true   // состояние не прочитали — свою речь не выбрасываем

        mutating func advance(to t: Double) {
            while i < events.count, events[i].t <= t {
                switch events[i].event {
                case .joined(let n): if mics[n] == nil { mics[n] = .unknown }
                case .left(let n): mics[n] = nil
                case .mic(let n, let on): mics[n] = on.map { $0 ? .on : .off } ?? .unknown
                case .myMic(let on): myMic = on
                case .title, .me: break
                }
                i += 1
            }
        }

        func names(_ state: Mic, excluding me: String) -> [String] {
            mics.filter { $0.value == state && $0.key != me }.keys.sorted()
        }
    }

    public static func attribute(mic: [Word], zoom: [Word], timeline: [TimedEvent], myName: String) -> [Utterance] {
        let events = timeline.enumerated().map { i, e -> (Int, TimedEvent) in
            switch e.event {
            case .mic(_, on: .some(true)), .myMic(on: true): return (i, TimedEvent(t: e.t - unmuteLead, event: e.event))
            default: return (i, e)
            }
        }.sorted { ($0.1.t, $0.0) < ($1.1.t, $1.0) }.map(\.1)

        var mine: [(Word, String)] = []
        var replay = Replay(events: events)
        for word in mic.sorted(by: { $0.start < $1.start }) {
            replay.advance(to: (word.start + word.end) / 2)
            if replay.myMic { mine.append((word, myName)) }
        }

        var theirs: [(Word, String)] = []
        replay = Replay(events: events)
        var prev: (speaker: String, end: Double)?
        for word in zoom.sorted(by: { $0.start < $1.start }) {
            replay.advance(to: (word.start + word.end) / 2)
            let on = replay.names(.on, excluding: myName)
            let continuing = prev.flatMap { word.start - $0.end <= continuityGap ? $0.speaker : nil }
            let speaker: String
            if on.count == 1 {
                speaker = on[0]
            } else if on.count > 1 {
                // ponytail: продолжающий фразу остаётся говорящим; реплику-вставку второго человека
                // так можно приписать первому. Лечится подписью по голосу на этапе 2.
                speaker = continuing.flatMap { on.contains($0) ? $0 : nil } ?? on.joined(separator: " / ")
            } else {
                let unknown = replay.names(.unknown, excluding: myName)
                speaker = continuing ?? (unknown.isEmpty ? unknownSpeaker : unknown.map { $0 + "?" }.joined(separator: " / "))
            }
            theirs.append((word, speaker))
            prev = (speaker, word.end)
        }

        return (group(mine) + group(theirs)).sorted { $0.start < $1.start }
    }

    private static func group(_ words: [(Word, String)]) -> [Utterance] {
        var out: [Utterance] = []
        var lastEnd = 0.0
        for (word, speaker) in words {
            if let last = out.last, last.speaker == speaker, word.start - lastEnd <= maxPause {
                out[out.count - 1].text += " " + word.text
            } else {
                out.append(Utterance(start: word.start, speaker: speaker, text: word.text))
            }
            lastEnd = word.end
        }
        return out
    }
}
```

`Sources/AviaCallsCore/TranscriptRenderer.swift`:
```swift
import Foundation

public enum TranscriptRenderer {
    public static func render(title: String, start: Date, participants: [String], utterances: [Utterance]) -> String {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n\(date.string(from: start))\nУчастники: \(participants.joined(separator: ", "))\n\n"
        for u in utterances {
            let s = Int(u.start)
            out += String(format: "[%02d:%02d:%02d] ", s / 3600, s / 60 % 60, s % 60) + "\(u.speaker): \(u.text)\n"
        }
        return out
    }
}
```

- [ ] **Step 4: тесты проходят**

Run: `swift test --filter "AttributorTests|TranscriptRendererTests"`
Expected: 14 тестов PASS.

- [ ] **Step 5: коммит**

```bash
git add -A && git commit -m "подпись реплик по микрофонам и рендер транскрипта" && git push
```

---

### Task 4: Хранение встречи

**Files:**
- Create: `Sources/AviaCallsCore/MeetingStore.swift`
- Test: `Tests/AviaCallsCoreTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: `TimedEvent`, `Word`
- Produces: `MeetingInfo`, `TrackWords`, `MeetingStore(root:start:)`, `MeetingStore(existing:)`, `dir`, `append(_:)`, `loadTimeline()`, `save(info:)`, `loadInfo()`, `save(words:)`, `loadWords()`, `save(transcript:)`, `audioURL(_:)`, `finalize(title:)`

- [ ] **Step 1: падающие тесты**

`Tests/AviaCallsCoreTests/MeetingStoreTests.swift`:
```swift
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
```

- [ ] **Step 2: тесты падают**

Run: `swift test --filter MeetingStoreTests`
Expected: `cannot find 'MeetingStore' in scope`.

- [ ] **Step 3: реализация**

`Sources/AviaCallsCore/MeetingStore.swift`:
```swift
import Foundation

public struct MeetingInfo: Codable, Equatable, Sendable {
    public var title: String?
    public var start: Date
    public var end: Date?
    public var participants: [String]
    public var myName: String?
    public var namesRead: Bool      // false — Zoom не отдал участников, транскрипт без имён
    public var micOffset: Double    // секунды от начала записи до первого звука дорожки
    public var zoomOffset: Double

    public init(title: String?, start: Date, end: Date?, participants: [String], myName: String?,
                namesRead: Bool, micOffset: Double, zoomOffset: Double) {
        self.title = title; self.start = start; self.end = end; self.participants = participants
        self.myName = myName; self.namesRead = namesRead; self.micOffset = micOffset; self.zoomOffset = zoomOffset
    }
}

public struct TrackWords: Codable, Equatable, Sendable {
    public var mic: [Word]
    public var zoom: [Word]
    public init(mic: [Word], zoom: [Word]) { self.mic = mic; self.zoom = zoom }
}

/// Папка одной встречи на диске.
public final class MeetingStore {
    public private(set) var dir: URL
    private let fm = FileManager.default

    public init(root: URL, start: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        dir = Self.free(root.appendingPathComponent(f.string(from: start)))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public init(existing dir: URL) { self.dir = dir }

    public func append(_ events: [TimedEvent]) throws {
        guard !events.isEmpty else { return }
        let url = dir.appendingPathComponent("timeline.jsonl")
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for e in events { try handle.write(contentsOf: try JSONEncoder().encode(e) + Data("\n".utf8)) }
    }

    public func loadTimeline() throws -> [TimedEvent] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("timeline.jsonl"), encoding: .utf8) else { return [] }
        // оборванную последнюю строку (приложение убили посреди записи) пропускаем
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(TimedEvent.self, from: Data($0.utf8)) }
    }

    public func save(info: MeetingInfo) throws { try write(info, "meeting.json") }
    public func loadInfo() throws -> MeetingInfo { try read("meeting.json") }
    public func save(words: TrackWords) throws { try write(words, "segments.json") }
    public func loadWords() -> TrackWords? { try? read("segments.json") }
    public func save(transcript: String) throws {
        try transcript.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    /// Дорожка `name`: несжатая, пока есть, иначе сжатая.
    public func audioURL(_ name: String) -> URL {
        let caf = dir.appendingPathComponent("\(name).caf"), m4a = dir.appendingPathComponent("\(name).m4a")
        return fm.fileExists(atPath: caf.path) || !fm.fileExists(atPath: m4a.path) ? caf : m4a
    }

    /// Дописывает название встречи в имя папки. Название узнаём не сразу, поэтому папка создаётся без него.
    @discardableResult
    public func finalize(title: String?) throws -> URL {
        let safe = (title ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return dir }
        let target = Self.free(dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent) \(safe.prefix(80))"))
        try fm.moveItem(at: dir, to: target)
        dir = target
        return dir
    }

    private static func free(_ url: URL) -> URL {
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) (\(n))")
            n += 1
        }
        return candidate
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func read<T: Decodable>(_ name: String) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }
}
```

- [ ] **Step 4: тесты проходят**

Run: `swift test`
Expected: все тесты PASS (40).

- [ ] **Step 5: коммит**

```bash
git add -A && git commit -m "хранение встречи: папка, таймлайн, meeting.json" && git push
```

---

### Task 5: Чтение Zoom через Accessibility, сборка .app

**Files:**
- Create: `Sources/AviaCalls/ZoomReader.swift`, `Sources/AviaCalls/CLI.swift`, `Resources/Info.plist`, `scripts/bundle.sh`
- Modify: `Sources/AviaCalls/main.swift`

**Interfaces:**
- Consumes: `AXNode`, `ZoomRawSnapshot`
- Produces: `ZoomReader().read() -> ZoomRawSnapshot?` (nil — окна встречи нет), `CLI.dumpAX()`, команда `--dump-ax`

- [ ] **Step 1: ZoomReader**

`Sources/AviaCalls/ZoomReader.swift`:
```swift
import AppKit
import ApplicationServices
import AviaCallsCore

/// Снимает дерево окна встречи Zoom через Accessibility. Только читает.
final class ZoomReader {
    static let bundleID = "us.zoom.xos"
    static let meetingWindowID = "zm.meeting.window.main"
    private static let attributes = [kAXRoleAttribute, kAXRoleDescriptionAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
                                     kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray

    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var muteItem: AXUIElement?

    func read() -> ZoomRawSnapshot? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            app = nil
            return nil
        }
        if app == nil || pid != running.processIdentifier {
            pid = running.processIdentifier
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 1)   // зависший Zoom не должен вешать нас
            app = el
            muteItem = nil
        }
        guard let app, let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: { copy($0, kAXIdentifierAttribute) as? String == Self.meetingWindowID })
        else { return nil }
        return ZoomRawSnapshot(window: node(window, depth: 0, parentRole: ""), muteMenuTitle: muteTitle(app))
    }

    private func copy(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private func node(_ el: AXUIElement, depth: Int, parentRole: String) -> AXNode {
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(el, Self.attributes, [], &raw)
        let values = raw as? [Any] ?? []
        func string(_ i: Int) -> String? {
            guard i < values.count, let s = values[i] as? String, !s.isEmpty else { return nil }
            return s
        }
        let role = string(0) ?? "?"
        var children: [AXNode] = []
        // кнопки Zoom отдают сами себя как ребёнка; без этой проверки обход не кончается
        if depth < 14, !(role == "AXButton" && parentRole == "AXButton"), values.count > 6, let kids = values[6] as? [AXUIElement] {
            children = kids.map { node($0, depth: depth + 1, parentRole: role) }
        }
        return AXNode(role: role, roleDescription: string(1), identifier: string(2), title: string(3),
                      description: string(4), value: string(5), children: children)
    }

    /// Название пункта меню «Выключить звук / Включить звук» — свой микрофон. Меню видно всегда, панель кнопок прячется.
    private func muteTitle(_ app: AXUIElement) -> String? {
        if let item = muteItem, let title = copy(item, kAXTitleAttribute) as? String { return title }
        muteItem = nil
        guard let bar = copy(app, kAXMenuBarAttribute) else { return nil }
        func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if copy(el, kAXIdentifierAttribute) as? String == "onMuteAudio:" { return el }
            guard depth < 4, let kids = copy(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for kid in kids { if let hit = find(kid, depth + 1) { return hit } }
            return nil
        }
        muteItem = find(bar as! AXUIElement, 0)
        return muteItem.flatMap { copy($0, kAXTitleAttribute) as? String }
    }
}
```

- [ ] **Step 2: CLI и main**

`Sources/AviaCalls/CLI.swift`:
```swift
import ApplicationServices
import AviaCallsCore
import Foundation

enum CLI {
    /// Печатает снимок окна встречи в JSON — так снимаем фикстуры для тестов.
    static func dumpAX() {
        guard AXIsProcessTrusted() else { fail("нет доступа: Системные настройки → Конфиденциальность → Универсальный доступ") }
        guard let snapshot = ZoomReader().read() else { fail("окно встречи Zoom не найдено") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(snapshot), as: UTF8.self))
        let parsed = ZoomTreeParser.parse(window: snapshot.window, muteMenuTitle: snapshot.muteMenuTitle)
        FileHandle.standardError.write(Data("разобрано: \(parsed)\n".utf8))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
```

`Sources/AviaCalls/main.swift`:
```swift
import Foundation

let args = CommandLine.arguments
if args.contains("--dump-ax") { CLI.dumpAX(); exit(0) }
print("AviaCalls: запусти с --dump-ax")
```

- [ ] **Step 3: Info.plist и сборка**

`Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ru.magir.aviacalls</string>
    <key>CFBundleName</key><string>AviaCalls</string>
    <key>CFBundleExecutable</key><string>AviaCalls</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>AviaCalls записывает твой голос на встречах, чтобы сделать транскрипт. Запись остаётся на этом компьютере.</string>
    <key>NSAudioCaptureUsageDescription</key><string>AviaCalls записывает звук Zoom, чтобы сделать транскрипт встречи. Запись остаётся на этом компьютере.</string>
</dict>
</plist>
```

`scripts/bundle.sh`:
```bash
#!/bin/bash
# Собирает build/AviaCalls.app и подписывает постоянным сертификатом:
# с ad-hoc подписью macOS после каждой сборки забывает выданные разрешения.
# ponytail: ресурсы SwiftPM-зависимостей ищутся по пути сборки на этой машине;
# для раздачи коллегам перейти на проект Xcode с нормальной упаковкой.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/AviaCalls.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AviaCalls "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign "${SIGN_IDENTITY:-Apple Development}" "$APP"
echo "$APP"
```
`chmod +x scripts/bundle.sh`

- [ ] **Step 4: проверка сборки**

Run: `swift build && swift test && scripts/bundle.sh && codesign -dv build/AviaCalls.app 2>&1 | grep Authority`
Expected: сборка без ошибок, тесты PASS, в выводе `Authority=Apple Development: Ivan Boitsov`.

- [ ] **Step 5: проверка на живом Zoom**

Нужна встреча в Zoom. Run: `.build/debug/AviaCalls --dump-ax > /tmp/snap.json`
Expected: в stderr строка `разобрано: ZoomSnapshot(...)` с верными именами и состоянием микрофонов. Без встречи: `окно встречи Zoom не найдено`, код выхода 1.

- [ ] **Step 6: коммит**

```bash
git add -A && git commit -m "чтение окна Zoom через Accessibility, сборка .app" && git push
```

---

### Task 6: Реальные фикстуры Zoom

Нужен Иван и телефон. Цель — проверить то, что спека вынесла в «проверяем первым шагом», и закрепить тестами.

**Files:**
- Create: `Tests/AviaCallsCoreTests/Fixtures/<сценарий>.json`, `Tests/AviaCallsCoreTests/FixtureTests.swift`
- Modify: `Sources/AviaCallsCore/ZoomTreeParser.swift` (если фикстуры покажут расхождения)

- [ ] **Step 1: снять фикстуры**

В каждом сценарии участников двое: мак (Иван) и телефон (“Тест Телефон”). Команда: `.build/debug/AviaCalls --dump-ax > Tests/AviaCallsCoreTests/Fixtures/<имя>.json`

| Файл | Сценарий |
|---|---|
| `host-panel-open.json` | Иван хост, панель участников открыта, Иван включён, телефон замьючен |
| `host-panel-closed.json` | то же, панель закрыта |
| `guest-panel-open.json` | хост — телефон, Иван зашёл участником, панель открыта |
| `guest-panel-closed.json` | то же, панель закрыта |
| `speaker-view.json` | вид «Докладчик» |
| `i-share-screen.json` | Иван показывает экран |
| `other-shares-screen.json` | экран показывает телефон |
| `minimized.json` | окно встречи свёрнуто |

Если в сценарии команда отвечает `окно встречи Zoom не найдено`, снять общий дамп спайк-скриптом `docs/spike/` и найти, как называется окно в этом режиме; идентификатор добавить в `ZoomReader`.

- [ ] **Step 2: тест на фикстуры**

`Tests/AviaCallsCoreTests/FixtureTests.swift` — по одному ожиданию на файл, значения берём из того, что реально было в Zoom в момент снятия:
```swift
import Foundation
import Testing
@testable import AviaCallsCore

private func load(_ name: String) throws -> ZoomSnapshot {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let raw = try JSONDecoder().decode(ZoomRawSnapshot.self, from: Data(contentsOf: url))
    return ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle)
}

@Suite struct FixtureTests {
    @Test(arguments: ["host-panel-open", "host-panel-closed", "guest-panel-open", "guest-panel-closed",
                      "speaker-view", "i-share-screen", "other-shares-screen", "minimized"])
    func seesBothParticipantsWithMicState(name: String) throws {
        let s = try load(name)
        #expect(Set(s.participants.map(\.name)) == ["Ivan Boitsov", "Тест Телефон"])
        #expect(s.participants.first { $0.name == "Ivan Boitsov" }?.micOn == true)
        #expect(s.participants.first { $0.name == "Тест Телефон" }?.micOn == false)
        #expect(s.myMicOn == true)
    }

    @Test(arguments: ["host-panel-open", "guest-panel-open"])
    func openPanelTellsWhoIsMe(name: String) throws {
        let s = try load(name)
        #expect(s.listOpen)
        #expect(s.participants.first { $0.isMe }?.name == "Ivan Boitsov")
    }
}
```

- [ ] **Step 3: довести разбор**

Run: `swift test --filter FixtureTests`
Каждый упавший сценарий — либо правка `ZoomTreeParser` (новые строки состояния, новые роли в `knownRoles`, другая структура строки списка у гостя), либо ограничение. Если в сценарии Zoom не отдаёт ни плиток, ни списка, тест для него переписываем на `#expect(s.participants.isEmpty)`, а сценарий вносим в спеку в раздел «Ошибки и края» как отрезок с неизвестным состоянием.

- [ ] **Step 4: все тесты проходят, коммит**

Run: `swift test`
```bash
git add -A && git commit -m "фикстуры живого Zoom и правки разбора" && git push
```

---

### Task 7: Захват звука

**Files:**
- Create: `Sources/AviaCalls/TrackWriter.swift`, `Sources/AviaCalls/ZoomTap.swift`, `Sources/AviaCalls/MicCapture.swift`, `Sources/AviaCalls/AudioCapture.swift`
- Modify: `Sources/AviaCalls/CLI.swift`, `Sources/AviaCalls/main.swift`

**Interfaces:**
- Produces: `AudioCapture().start(dir: URL, at: Date) throws`, `stop() -> (micOffset: Double, zoomOffset: Double)`, `zoomAlive: Bool`; файлы `mic.caf`, `zoom.caf` в `dir`; команда `--record-test <секунд>`

- [ ] **Step 1: TrackWriter**

`Sources/AviaCalls/TrackWriter.swift`:
```swift
import AVFoundation

/// Пишет дорожку в CAF 16 кГц моно int16: Whisper читает его без пересчёта, а файл переживает падение приложения.
final class TrackWriter {
    static let sampleRate = 16000.0
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "aviacalls.trackwriter")
    private let start: Date
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var written: Int64 = 0
    private var offset: Double?

    init(url: URL, start: Date) throws {
        self.start = start
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatInt16, interleaved: false)
    }

    var alive: Bool { queue.sync { offset != nil } }

    /// Буфер жив только на время вызова, поэтому пишем синхронно.
    func append(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        queue.sync { write(buffer, at: now) }
    }

    /// Закрывает файл; возвращает секунды от начала записи до первого звука дорожки.
    func close() -> Double {
        queue.sync {
            file = nil
            return offset ?? 0
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, at now: Date) {
        guard let file, buffer.frameLength > 0 else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let elapsed = now.timeIntervalSince(start)
        if offset == nil { offset = max(0, elapsed - duration) }

        // дыра после смены устройства: добиваем тишиной, иначе время в файле уедет относительно таймлайна
        let expected = Int64((elapsed - duration - offset!) * Self.sampleRate)
        if expected - written > Int64(Self.sampleRate / 2) { silence(expected - written, into: file) }

        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
            if buffer.format.channelCount > 1 { converter?.channelMap = [0] }
        }
        let capacity = AVAudioFrameCount(duration * Self.sampleRate) + 64
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0 else { return }
        try? file.write(from: out)
        written += Int64(out.frameLength)
    }

    private func silence(_ frames: Int64, into file: AVAudioFile) {
        var left = frames
        while left > 0 {
            let n = AVAudioFrameCount(min(left, 16000))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return }
            buf.frameLength = n   // буфер создаётся обнулённым
            try? file.write(from: buf)
            left -= Int64(n)
            written += Int64(n)
        }
    }
}
```

- [ ] **Step 2: ZoomTap**

`Sources/AviaCalls/ZoomTap.swift`:
```swift
import AVFoundation
import CoreAudio

/// Забирает звук, который проигрывает Zoom, через Core Audio process tap (macOS 14.4+).
final class ZoomTap {
    private let writer: TrackWriter
    private let queue = DispatchQueue(label: "aviacalls.zoomtap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var outputAddress = address(kAudioHardwarePropertyDefaultOutputDevice)

    init(writer: TrackWriter) { self.writer = writer }

    func start() {
        queue.sync {
            running = true
            // сменили устройство вывода (подключили наушники) — агрегат привязан к старому, пересобираем
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reopen() }
            listener = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, queue, block)
            reopen()
        }
    }

    func stop() {
        queue.sync {
            running = false
            if let listener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, queue, listener) }
            listener = nil
            close()
        }
    }

    private func reopen() {
        guard running else { return }
        close()
        do { try open() } catch {
            // Zoom ещё не подключил звук или нет разрешения — пробуем снова; тишину TrackWriter добьёт сам
            close()
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.deviceID == kAudioObjectUnknown else { return }
                self.reopen()
            }
        }
    }

    private func open() throws {
        let processes = try Self.zoomProcesses()
        guard !processes.isEmpty else { throw TapError("Zoom не найден среди аудиопроцессов") }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "создать tap")

        var asbd = AudioStreamBasicDescription()
        try read(tapID, kAudioTapPropertyFormat, &asbd)
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw TapError("непонятный формат tap") }

        var output = AudioObjectID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &output)
        var uid = "" as CFString
        try read(output, kAudioDevicePropertyDeviceUID, &uid)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AviaCalls",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "создать агрегатное устройство")

        let writer = self.writer
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.append(buffer)
        }, "создать IOProc")
        try check(AudioDeviceStart(deviceID, procID), "запустить устройство")
    }

    private func close() {
        if deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    /// Все аудиопроцессы Zoom: звук может играть не главный процесс, а помощник.
    static func zoomProcesses() throws -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size), "список аудиопроцессов")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids), "список аудиопроцессов")
        return ids.filter { id in
            var bundle = "" as CFString
            return (try? read(id, kAudioProcessPropertyBundleID, &bundle)) != nil && (bundle as String).hasPrefix("us.zoom")
        }
    }
}

struct TapError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw TapError("не удалось \(what): OSStatus \(status)") }
}

private func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) throws {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "прочитать свойство \(selector)")
}
```

- [ ] **Step 3: MicCapture и AudioCapture**

`Sources/AviaCalls/MicCapture.swift`:
```swift
import AVFoundation

/// Микрофон с системным эхоподавлением, чтобы голоса из динамиков не попадали в дорожку пользователя.
final class MicCapture {
    private let writer: TrackWriter
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    init(writer: TrackWriter) { self.writer = writer }

    func start() throws {
        // ручка на случай, если эхоподавление мешает Zoom: defaults write ru.magir.aviacalls micVoiceProcessing -bool NO
        if UserDefaults.standard.object(forKey: "micVoiceProcessing") as? Bool ?? true {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // без этого система приглушает звук остальных приложений, включая сам Zoom
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        try run()
        // сменился микрофон — движок останавливается сам, поднимаем заново
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            try? self?.run()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func run() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in writer.append(buffer) }
        try engine.start()
    }
}
```

`Sources/AviaCalls/AudioCapture.swift`:
```swift
import Foundation

/// Пишет две дорожки встречи: mic.caf и zoom.caf.
final class AudioCapture {
    private var mic: MicCapture?
    private var zoom: ZoomTap?
    private var micWriter: TrackWriter?
    private var zoomWriter: TrackWriter?

    /// Пошёл ли звук Zoom. false через 15 секунд после старта — скорее всего, нет разрешения на захват звука.
    var zoomAlive: Bool { zoomWriter?.alive ?? false }

    func start(dir: URL, at start: Date) throws {
        let zoomWriter = try TrackWriter(url: dir.appendingPathComponent("zoom.caf"), start: start)
        let micWriter = try TrackWriter(url: dir.appendingPathComponent("mic.caf"), start: start)
        let zoom = ZoomTap(writer: zoomWriter)
        let mic = MicCapture(writer: micWriter)
        zoom.start()
        do { try mic.start() } catch { zoom.stop(); throw error }
        (self.zoom, self.mic, self.zoomWriter, self.micWriter) = (zoom, mic, zoomWriter, micWriter)
    }

    func stop() -> (micOffset: Double, zoomOffset: Double) {
        mic?.stop()
        zoom?.stop()
        let offsets = (micWriter?.close() ?? 0, zoomWriter?.close() ?? 0)
        (mic, zoom, micWriter, zoomWriter) = (nil, nil, nil, nil)
        return offsets
    }
}
```

- [ ] **Step 4: команда --record-test**

В `CLI.swift` добавить:
```swift
    /// Пишет обе дорожки N секунд во временную папку — ручная проверка захвата.
    static func recordTest(seconds: Double) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-record-\(Int(Date().timeIntervalSince1970))")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = AudioCapture()
        do { try audio.start(dir: dir, at: Date()) } catch { fail("захват не стартовал: \(error)") }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let alive = audio.zoomAlive
        let offsets = audio.stop()
        print("папка: \(dir.path)\nzoom пошёл: \(alive)\nсмещения: mic \(offsets.micOffset), zoom \(offsets.zoomOffset)")
    }
```
В `main.swift` перед последней строкой:
```swift
if let i = args.firstIndex(of: "--record-test") { CLI.recordTest(seconds: Double(args.dropFirst(i + 1).first ?? "") ?? 10); exit(0) }
```

- [ ] **Step 5: сборка**

Run: `swift build 2>&1 | tail -20`
Expected: без ошибок. Ошибки сигнатур Core Audio чинить по заголовкам SDK (`CoreAudio/AudioHardwareTapping.h`, `CoreAudio/CATapDescription.h`).

- [ ] **Step 6: ручная проверка на встрече**

Нужна встреча с телефоном, телефон говорит, мак без наушников.

1. `.build/debug/AviaCalls --record-test 20`, в это время говорить по очереди в мак и в телефон. Expected: `zoom пошёл: true`.
2. `afinfo <папка>/zoom.caf <папка>/mic.caf` — оба файла около 20 секунд, 16000 Hz, 1 ch.
3. `afplay <папка>/zoom.caf` — слышен только телефон. `afplay <папка>/mic.caf` — слышен только Иван, голос телефона из динамиков подавлен.
4. Во время записи звук Zoom в динамиках не становится тише.
5. Смена устройства: `--record-test 30`, на 10-й секунде переключить вывод на наушники. Expected: длительность `zoom.caf` около 30 секунд, речь слышна до и после переключения.
6. Падение: `--record-test 30`, на 15-й секунде `kill -9` процесса. Expected: `afinfo` открывает оба файла, длительность около 15 секунд.

Если пункт 6 не проходит (CAF не читается без закрытия) — заменить в `TrackWriter` `AVAudioFile` на `FileHandle` с сырым PCM (`.pcm`) и оборачивать в CAF при остановке и при `--transcribe`. Если не проходит пункт 3 или 4 — выключить эхоподавление по умолчанию и записать в README, что без наушников реплики собеседников дублируются в дорожке Ивана.

- [ ] **Step 7: коммит**

```bash
git add -A && git commit -m "захват звука: дорожка Zoom и микрофон" && git push
```

---

### Task 8: Транскрибация и сборка транскрипта

**Files:**
- Create: `Sources/AviaCalls/Transcriber.swift`, `Sources/AviaCalls/Pipeline.swift`
- Modify: `Package.swift`, `Sources/AviaCalls/CLI.swift`, `Sources/AviaCalls/main.swift`

**Interfaces:**
- Consumes: `MeetingStore`, `MeetingInfo`, `TrackWords`, `Attributor`, `TranscriptRenderer`
- Produces: `actor Transcriber { func words(audio: URL, offset: Double) async throws -> [Word] }`, `Pipeline.process(dir: URL, transcriber: Transcriber) async throws`; команда `--transcribe <папка>`

- [ ] **Step 1: зависимость**

В `Package.swift` добавить в `Package(...)`:
```swift
    dependencies: [.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")],
```
и в `executableTarget` зависимости: `["AviaCallsCore", .product(name: "WhisperKit", package: "WhisperKit")]`.

Run: `swift package resolve && swift package show-dependencies | head`
Записать поставленную версию WhisperKit в сообщение коммита.

- [ ] **Step 2: Transcriber**

`Sources/AviaCalls/Transcriber.swift`:
```swift
import AviaCallsCore
import Foundation
import WhisperKit

/// Локальная транскрибация. Модель скачивается один раз при первом запуске, дальше сеть не нужна.
actor Transcriber {
    // ручка: defaults write ru.magir.aviacalls whisperModel <имя>
    static var model: String { UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo" }
    private var pipe: WhisperKit?

    func words(audio: URL, offset: Double) async throws -> [Word] {
        if pipe == nil { pipe = try await WhisperKit(WhisperKitConfig(model: Self.model)) }
        // VAD режет тишину: на длинных паузах Whisper выдумывает текст
        let options = DecodingOptions(task: .transcribe, language: nil, detectLanguage: true,
                                      skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        let results = try await pipe!.transcribe(audioPath: audio.path, decodeOptions: options)
        return results.flatMap(\.allWords).compactMap { w in
            let text = w.word.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : Word(start: Double(w.start) + offset, end: Double(w.end) + offset, text: text)
        }
    }
}
```
Имена параметров сверить с поставленной версией: `swift build` покажет расхождения, исходники лежат в `.build/checkouts/WhisperKit/Sources/WhisperKit/Core/`. Список моделей: `WhisperKit.fetchAvailableModels()`.

- [ ] **Step 3: Pipeline**

`Sources/AviaCalls/Pipeline.swift`:
```swift
import AviaCallsCore
import Foundation

enum Pipeline {
    /// Папка встречи → transcript.md. Если segments.json уже есть, Whisper не запускается — только заново подписываются имена.
    static func process(dir: URL, transcriber: Transcriber) async throws {
        let store = MeetingStore(existing: dir)
        let info = try store.loadInfo()
        let timeline = try store.loadTimeline()

        let words: TrackWords
        if let saved = store.loadWords() {
            words = saved
        } else {
            words = TrackWords(mic: try await transcriber.words(audio: store.audioURL("mic"), offset: info.micOffset),
                               zoom: try await transcriber.words(audio: store.audioURL("zoom"), offset: info.zoomOffset))
            try store.save(words: words)
        }

        let utterances = Attributor.attribute(mic: words.mic, zoom: words.zoom, timeline: timeline, myName: info.myName ?? "Я")
        try store.save(transcript: TranscriptRenderer.render(title: info.title ?? "Встреча", start: info.start,
                                                             participants: info.participants, utterances: utterances))
        for name in ["mic", "zoom"] { compress(dir.appendingPathComponent("\(name).caf")) }
    }

    /// CAF → m4a системным afconvert; исходник удаляем только при успехе.
    private static func compress(_ caf: URL) {
        guard FileManager.default.fileExists(atPath: caf.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac", "-b", "32000", caf.path, caf.deletingPathExtension().appendingPathExtension("m4a").path]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        if process.terminationStatus == 0 { try? FileManager.default.removeItem(at: caf) }
    }
}
```

- [ ] **Step 4: команда --transcribe**

В `CLI.swift`:
```swift
    /// Собирает транскрипт для готовой папки встречи — восстановление после падения и пересборка после улучшений.
    static func transcribe(dir: String) {
        let done = DispatchSemaphore(value: 0)
        Task {
            do { try await Pipeline.process(dir: URL(fileURLWithPath: dir), transcriber: Transcriber()) } catch { fail("не получилось: \(error)") }
            done.signal()
        }
        done.wait()
        print("готово: \(dir)/transcript.md")
    }
```
В `MeetingStore.loadInfo` падение без `meeting.json` (приложение убили до первого сохранения) недопустимо для восстановления, поэтому в `Pipeline.process` заменить `try store.loadInfo()` на:
```swift
        let info = (try? store.loadInfo()) ?? MeetingInfo(title: nil, start: Date(), end: nil, participants: [], myName: nil, namesRead: false, micOffset: 0, zoomOffset: 0)
```
В `main.swift`:
```swift
if let i = args.firstIndex(of: "--transcribe"), let dir = args.dropFirst(i + 1).first { CLI.transcribe(dir: dir); exit(0) }
```

- [ ] **Step 5: сборка и проверка**

Run: `swift build 2>&1 | tail -20 && swift test`
Expected: сборка без ошибок, тесты PASS.

Ручная проверка на папке из задачи 7 (20 секунд речи): `.build/debug/AviaCalls --transcribe <папка>`
Expected: первый запуск качает модель (около 1,6 ГБ), затем появляются `segments.json` и `transcript.md` с русской и английской речью; оба `.caf` заменены на `.m4a`. Повторный запуск проходит за секунду и Whisper не трогает. Без таймлайна все слова дорожки Zoom подписаны «Неизвестный» — это ожидаемо.

- [ ] **Step 6: коммит**

```bash
git add -A && git commit -m "транскрибация WhisperKit и сборка транскрипта" && git push
```

---

### Task 9: Контроллер записи и менюбар

**Files:**
- Create: `Sources/AviaCalls/RecorderController.swift`, `Sources/AviaCalls/AviaCallsApp.swift`, `README.md`
- Modify: `Sources/AviaCalls/main.swift`

**Interfaces:**
- Consumes: `ZoomReader`, `ZoomTreeParser`, `TimelineBuilder`, `MeetingStore`, `MeetingInfo`, `AudioCapture`, `Transcriber`, `Pipeline`

- [ ] **Step 1: RecorderController**

`Sources/AviaCalls/RecorderController.swift`:
```swift
import AppKit
import ApplicationServices
import AVFoundation
import AviaCallsCore
import UserNotifications

/// Следит за Zoom и ведёт запись: встреча началась → пишем, закончилась → транскрибируем.
@MainActor
final class RecorderController: ObservableObject {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Meetings")
    static let pollInterval = 0.3
    static let endAfter = 10.0   // секунд без окна встречи — встреча закончилась

    @Published private(set) var recording = false
    @Published private(set) var jobs = 0
    @Published private(set) var lastFolder: URL?
    @Published private(set) var failedFolder: URL?
    @Published private(set) var problem: String?

    private let reader = ZoomReader()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()
    private var timer: Timer?
    private var store: MeetingStore?
    private var builder = TimelineBuilder(myName: nil)
    private var info: MeetingInfo?
    private var lastSeen = Date.distantPast
    private var suppressed = false   // пользователь остановил запись или она не стартовала: ждём конца этой встречи

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        // ponytail: опрос Accessibility идёт в главном потоке; у приложения нет окон, подвисать нечему
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var statusText: String {
        if recording { return "Идёт запись" }
        if jobs > 0 { return "Транскрибирую…" }
        return "Жду встречу в Zoom"
    }

    func stopByUser() {
        suppressed = true
        finish(Date())
    }

    func retry() {
        guard let dir = failedFolder else { return }
        failedFolder = nil
        transcribe(dir)
    }

    private func tick() {
        guard AXIsProcessTrusted() else {
            problem = "Нет доступа: Системные настройки → Конфиденциальность → Универсальный доступ"
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            problem = "Нет доступа к микрофону"
            return
        }
        let now = Date()
        guard let raw = reader.read() else {
            if now.timeIntervalSince(lastSeen) > Self.endAfter {
                suppressed = false
                if recording { finish(now) }
            }
            return
        }
        lastSeen = now
        if !recording && !suppressed { begin(now) }
        guard recording, var info, let store else { return }

        let events = builder.ingest(ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle),
                                    at: now.timeIntervalSince(info.start))
        guard !events.isEmpty else { checkZoomAudio(now, info); return }
        for e in events {
            switch e.event {
            case .title(let t): info.title = t
            case .joined(let n): if !info.participants.contains(n) { info.participants.append(n) }
            case .me(let n): UserDefaults.standard.set(n, forKey: "myName")
            default: break
            }
        }
        info.myName = builder.myName
        info.namesRead = !info.participants.isEmpty
        self.info = info
        // meeting.json пишем по ходу, чтобы после падения встречу можно было восстановить через --transcribe
        do { try store.append(events); try store.save(info: info) } catch { problem = "Не пишется на диск: \(error.localizedDescription)" }
    }

    private func begin(_ now: Date) {
        do {
            let store = try MeetingStore(root: Self.root, start: now)
            try audio.start(dir: store.dir, at: now)
            self.store = store
            builder = TimelineBuilder(myName: UserDefaults.standard.string(forKey: "myName"))
            info = MeetingInfo(title: nil, start: now, end: nil, participants: [], myName: builder.myName,
                               namesRead: false, micOffset: 0, zoomOffset: 0)
            recording = true
            problem = nil
            notify("Идёт запись встречи", "Предупреди участников, что встреча записывается.")
        } catch {
            suppressed = true
            problem = "Запись не стартовала: \(error.localizedDescription)"
        }
    }

    private func finish(_ now: Date) {
        guard recording, var info, let store else { return }
        recording = false
        let offsets = audio.stop()
        info.end = now
        info.micOffset = offsets.micOffset
        info.zoomOffset = offsets.zoomOffset
        if !info.namesRead { problem = "Имена участников не прочитаны: Zoom изменил интерфейс?" }
        try? store.save(info: info)
        let dir = (try? store.finalize(title: info.title)) ?? store.dir
        (self.store, self.info) = (nil, nil)
        lastFolder = dir
        transcribe(dir)
    }

    private func transcribe(_ dir: URL) {
        jobs += 1
        Task {
            do { try await Pipeline.process(dir: dir, transcriber: transcriber) } catch {
                failedFolder = dir
                problem = "Транскрибация упала: \(error.localizedDescription)"
            }
            jobs -= 1
        }
    }

    private func checkZoomAudio(_ now: Date, _ info: MeetingInfo) {
        if now.timeIntervalSince(info.start) > 15, !audio.zoomAlive {
            problem = "Нет звука Zoom: проверь разрешение «Запись системного звука» для AviaCalls"
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
```

- [ ] **Step 2: менюбар и main**

`Sources/AviaCalls/AviaCallsApp.swift`:
```swift
import SwiftUI

struct AviaCallsApp: App {
    @StateObject private var recorder = RecorderController()

    var body: some Scene {
        MenuBarExtra("AviaCalls", systemImage: recorder.recording ? "record.circle.fill" : (recorder.jobs > 0 ? "text.bubble" : "record.circle")) {
            Text(recorder.statusText)
            if let problem = recorder.problem { Text(problem) }
            Divider()
            if recorder.recording { Button("Остановить запись") { recorder.stopByUser() } }
            if recorder.failedFolder != nil { Button("Повторить транскрибацию") { recorder.retry() } }
            if let folder = recorder.lastFolder { Button("Открыть последнюю встречу") { NSWorkspace.shared.open(folder) } }
            Button("Открыть папку встреч") { NSWorkspace.shared.open(RecorderController.root) }
            Divider()
            Button("Выйти") { NSApp.terminate(nil) }
        }
    }
}
```
В `main.swift` заменить последнюю строку (`print(...)`) на `AviaCallsApp.main()`.

- [ ] **Step 3: README**

`README.md` — сборка и первый запуск:
````markdown
# AviaCalls

Записывает встречи в Zoom и делает транскрипт с именами говорящих. Всё локально.

## Сборка

Нужны Xcode и сертификат Apple Development (Xcode → Settings → Accounts).

```bash
scripts/bundle.sh
open build/AviaCalls.app
```

## Разрешения при первом запуске

- **Универсальный доступ** — читать список участников и состояние микрофонов в окне Zoom. Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → добавить AviaCalls.
- **Микрофон** — запрос появится сам.
- **Запись системного звука** — запрос появится на первой встрече.

Первая транскрибация скачивает модель Whisper (около 1,6 ГБ).

## Как пользоваться

Приложение живёт в менюбаре. Запись начинается сама, когда открывается окно встречи Zoom, и заканчивается, когда оно закрывается. Результат — в `~/Documents/Meetings/`.

Zoom не показывает участникам, что идёт запись. Предупреждай их сам.

## Команды для отладки

```bash
build/AviaCalls.app/Contents/MacOS/AviaCalls --dump-ax              # снимок окна встречи в JSON
build/AviaCalls.app/Contents/MacOS/AviaCalls --record-test 20       # записать 20 секунд во временную папку
build/AviaCalls.app/Contents/MacOS/AviaCalls --transcribe <папка>   # пересобрать транскрипт встречи
```

## Настройки

```bash
defaults write ru.magir.aviacalls micVoiceProcessing -bool NO   # выключить эхоподавление микрофона
defaults write ru.magir.aviacalls whisperModel <имя>            # другая модель Whisper
defaults write ru.magir.aviacalls myName "Имя в Zoom"           # если приложение не узнало, кто из участников ты
```
````

- [ ] **Step 4: сборка**

Run: `swift build 2>&1 | tail -20 && swift test && scripts/bundle.sh`
Expected: без ошибок, тесты PASS, собран `build/AviaCalls.app`.

- [ ] **Step 5: сквозная проверка на встрече**

`open build/AviaCalls.app`, выдать разрешения. Встреча с телефоном (“Тест Телефон”), панель участников закрыта.

1. Через пару секунд после начала встречи иконка в менюбаре меняется, приходит уведомление «Идёт запись встречи».
2. Сценарий речи: Иван говорит 10 секунд; телефон говорит 10 секунд, Иван замьючен и в это время говорит вслух мимо Zoom; оба включены, говорит телефон; телефон замьючен, говорит Иван.
3. Завершить встречу. Через 10 секунд статус «Транскрибирую…», затем «Жду встречу в Zoom».
4. «Открыть последнюю встречу»: папка названа `<дата время> <название встречи>`, внутри `meeting.json`, `timeline.jsonl`, `segments.json`, `transcript.md`, `mic.m4a`, `zoom.m4a`.
5. В `transcript.md`: название и оба участника в шапке; реплики телефона подписаны “Тест Телефон”; реплики Ивана подписаны его именем; слова, сказанные Иваном при выключенном микрофоне, отсутствуют; время реплик совпадает со сценарием с точностью до пары секунд.
6. «Остановить запись» посреди встречи: запись заканчивается и не начинается заново, пока встреча не закрыта; на следующей встрече запись стартует сама.
7. Убить приложение посреди встречи (`kill -9`), затем `--transcribe <папка>`: транскрипт собирается из того, что успело записаться.

Найденные расхождения — отдельными коммитами с тестом там, где логика в `AviaCallsCore`.

- [ ] **Step 6: коммит**

```bash
git add -A && git commit -m "контроллер записи, менюбар, README" && git push
```

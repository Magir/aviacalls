import Foundation
import Testing
@testable import AviaCallsCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-lib-\(UUID().uuidString)")
}
private func info(_ title: String?, _ start: Date, _ participants: [String] = []) -> MeetingInfo {
    MeetingInfo(title: title, start: start, end: start.addingTimeInterval(600), participants: participants, myName: nil,
                namesRead: true, micOffset: 0, zoomOffset: 0)
}
private let day1 = Date(timeIntervalSince1970: 1_790_000_000), day2 = Date(timeIntervalSince1970: 1_790_090_000)

@Suite struct MeetingLibraryTests {
    @Test func listsMeetingsNewestFirst() throws {
        let root = tempRoot()
        let old = try MeetingStore(root: root, start: day1)
        try old.save(info: info("Старая", day1, ["Ann", "Bob"]))
        try old.save(transcript: "x")
        let new = try MeetingStore(root: root, start: day2)
        try new.save(info: info("Новая", day2))
        try Data().write(to: new.dir.appendingPathComponent("zoom.caf"))

        let list = MeetingLibrary.load(root: root)
        #expect(list.map(\.title) == ["Новая", "Старая"])
        #expect(list.map(\.hasTranscript) == [false, true])
        #expect(list.map(\.hasAudio) == [true, false])
        #expect(list[1].participants == ["Ann", "Bob"])
        #expect(list[1].end == day1.addingTimeInterval(600))
    }

    @Test func untitledMeetingGetsPlaceholderTitle() throws {
        let root = tempRoot()
        try MeetingStore(root: root, start: day1).save(info: info(nil, day1))
        #expect(MeetingLibrary.load(root: root).map(\.title) == ["Встреча"])
    }

    @Test func crashedRecordingWithoutMeetingJsonIsListedByFolderName() throws {
        let root = tempRoot()
        let store = try MeetingStore(root: root, start: day1)
        try Data().write(to: store.dir.appendingPathComponent("mic.caf"))
        let list = MeetingLibrary.load(root: root)
        #expect(list.count == 1)
        #expect(list[0].title == "Встреча")
        #expect(abs(list[0].start.timeIntervalSince(day1)) < 60)   // в имени папки время с точностью до минуты
        #expect(list[0].hasAudio)
    }

    @Test func ignoresFilesAndForeignFolders() throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("заметки"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.txt"))
        #expect(MeetingLibrary.load(root: root).isEmpty)
        #expect(MeetingLibrary.load(root: tempRoot()).isEmpty)   // папки ещё нет
    }

    @Test func participantsLineShortensLongLists() {
        #expect(MeetingLibrary.participantsLine([]) == "")
        #expect(MeetingLibrary.participantsLine(["Ann", "Bob", "Cid"]) == "Ann, Bob, Cid")
        #expect(MeetingLibrary.participantsLine(["Ann", "Bob", "Cid", "Dan", "Eve"]) == "Ann, Bob, Cid и ещё 2")
    }

    @Test func parsesTranscriptLines() {
        let text = "# Sync\n\n2026-10-01 23:25\nУчастники: John Doe\n\n[00:12:43] John Doe: Hello: everyone\n[01:02:05] Ann / Bob: да\nмусор\n"
        #expect(MeetingLibrary.lines(text) == [
            TranscriptLine(id: 0, time: "00:12:43", speaker: "John Doe", text: "Hello: everyone"),
            TranscriptLine(id: 1, time: "01:02:05", speaker: "Ann / Bob", text: "да"),
        ])
    }
}

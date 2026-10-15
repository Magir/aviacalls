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

    @Test func searchesAcrossAllTranscripts() throws {
        let root = tempRoot()
        let a = try MeetingStore(root: root, start: day1)
        try a.save(info: info("Первая", day1))
        try a.save(transcript: "# Первая\n\n[00:00:10] Ann: Дашборд по BDM готов\n[00:00:20] Bob: ещё дашборд по камам\n")
        let b = try MeetingStore(root: root, start: day2)
        try b.save(info: info("Вторая", day2))
        try b.save(transcript: "# Вторая\n\n[00:00:05] Ann: про метки сейлов\n")
        let hits = MeetingLibrary.search(root: root, query: "дашборд")
        #expect(hits.map(\.meeting.title) == ["Первая"])
        #expect(hits[0].lines.map(\.text) == ["Дашборд по BDM готов", "ещё дашборд по камам"])
        #expect(MeetingLibrary.search(root: root, query: "bdm").count == 1)      // регистр не важен
        #expect(MeetingLibrary.search(root: root, query: "еще").count == 1)      // ё и е равны
        #expect(MeetingLibrary.search(root: root, query: "  ").isEmpty)
        // по названию и участникам тоже, даже если в тексте запроса нет
        let byTitle = MeetingLibrary.search(root: root, query: "вторая")
        #expect(byTitle.map(\.meeting.title) == ["Вторая"])
        #expect(byTitle[0].lines.isEmpty)
        let c = try MeetingStore(root: root, start: day2.addingTimeInterval(3600))
        try c.save(info: info("Третья", day2.addingTimeInterval(3600), ["Irina Osadchaya"]))
        #expect(MeetingLibrary.search(root: root, query: "osadchaya").map(\.meeting.title) == ["Третья"])
    }

    @Test func filtersLinesOfOneTranscript() {
        let lines = [TranscriptLine(id: 0, time: "00:00:10", speaker: "Ann", text: "Дашборд готов"),
                     TranscriptLine(id: 1, time: "00:00:20", speaker: "Bob", text: "про метки")]
        #expect(MeetingLibrary.filter(lines, query: "ГОТОВ").map(\.id) == [0])
        #expect(MeetingLibrary.filter(lines, query: "bob").map(\.id) == [1])      // по имени тоже
        #expect(MeetingLibrary.filter(lines, query: "").count == 2)
    }

    @Test func searchesCorrectedTranscriptOnlyWhileSourceMatches() throws {
        let root = tempRoot()
        let store = try MeetingStore(root: root, start: day1)
        try store.save(info: info("Встреча", day1))
        let original = "[00:00:01] Ann: Арбита готова\n"
        try store.save(transcript: original)
        try TranscriptCorrection.save("[00:00:01] Ann: Орбита готова\n", source: original, in: store.dir)
        #expect(MeetingLibrary.search(root: root, query: "Орбита").count == 1)
        #expect(MeetingLibrary.search(root: root, query: "Арбита").isEmpty)
        try store.save(transcript: "[00:00:01] Ann: Новый исходник\n")
        #expect(MeetingLibrary.search(root: root, query: "Орбита").isEmpty)
        #expect(MeetingLibrary.search(root: root, query: "исходник").count == 1)
    }

    @Test func searchSnapshotKeepsPreparedSourceUntilItIsRebuilt() throws {
        let root = tempRoot()
        let store = try MeetingStore(root: root, start: day1)
        try store.save(info: info("Встреча", day1))
        let original = "[00:00:01] Ann: Арбита готова\n"
        try store.save(transcript: original)
        try TranscriptCorrection.save("[00:00:01] Ann: Орбита готова\n", source: original, in: store.dir)

        let prepared = MeetingLibrary.searchSnapshot(root: root)
        #expect(prepared.search(query: "Орбита").count == 1)
        #expect(prepared.search(query: "Арбита").isEmpty)

        try store.save(transcript: "[00:00:01] Ann: Новый исходник\n")
        #expect(prepared.search(query: "Орбита").count == 1)
        #expect(MeetingLibrary.searchSnapshot(root: root).search(query: "Орбита").isEmpty)
        #expect(MeetingLibrary.searchSnapshot(root: root).search(query: "исходник").count == 1)
    }

    @Test func cancellableSnapshotSearchDiscardsCancelledResult() async throws {
        let root = tempRoot()
        for (offset, title) in ["Первая", "Вторая"].enumerated() {
            let start = day1.addingTimeInterval(TimeInterval(offset))
            let store = try MeetingStore(root: root, start: start)
            try store.save(info: info(title, start))
            try store.save(transcript: "[00:00:01] Ann: совпадение\n")
        }
        let snapshot = MeetingLibrary.searchSnapshot(root: root)
        let task = Task { () -> [MeetingLibrary.SearchHit] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await snapshot.searchCancellable(query: "совпадение")
        }
        #expect((await task.value).isEmpty)
    }

    @Test func snapshotDetectsExternalTranscriptAndLibraryChanges() throws {
        let root = tempRoot()
        let store = try MeetingStore(root: root, start: day1)
        try store.save(info: info("Первая", day1))
        let source = "[00:00:01] Ann: aaa\n"
        try store.save(transcript: source)
        let initial = MeetingLibrary.searchSnapshot(root: root)
        #expect(initial.isCurrent(root: root))

        try store.save(transcript: "[00:00:01] Ann: bbb\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
                                              ofItemAtPath: store.dir.appendingPathComponent("transcript.md").path)
        #expect(!initial.isCurrent(root: root))

        let afterSource = MeetingLibrary.searchSnapshot(root: root)
        try TranscriptCorrection.save("[00:00:01] Ann: ccc\n", source: "[00:00:01] Ann: bbb\n", in: store.dir)
        #expect(!afterSource.isCurrent(root: root))

        let withCorrected = MeetingLibrary.searchSnapshot(root: root)
        try FileManager.default.removeItem(at: store.dir.appendingPathComponent("transcript.corrected.md"))
        #expect(!withCorrected.isCurrent(root: root))

        let afterCorrectionRemoval = MeetingLibrary.searchSnapshot(root: root)
        let newStore = try MeetingStore(root: root, start: day2)
        try newStore.save(info: info("Вторая", day2))
        #expect(!afterCorrectionRemoval.isCurrent(root: root))
    }

    @Test func escapesPathForShell() {
        #expect(MeetingLibrary.shellPath("/Users/m/Meetings/2026-10-05 13-05 Планирование (метрики)") == "/Users/m/Meetings/2026-10-05\\ 13-05\\ Планирование\\ \\(метрики\\)")
        #expect(MeetingLibrary.shellPath("/plain/path") == "/plain/path")
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

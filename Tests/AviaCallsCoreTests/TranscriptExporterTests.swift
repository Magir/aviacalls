import Foundation
import Testing
@testable import AviaCallsCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-export-\(UUID().uuidString)")
}
private let start = MeetingStore.stamp.date(from: "2026-10-26 14-00")!

@Suite struct TranscriptExporterTests {
    @Test func slugTransliteratesAndCollapses() {
        #expect(TranscriptExporter.slug("Синк по релизу: Q4 / план") == "sink-po-relizu-q4-plan")
        #expect(TranscriptExporter.slug("Объявление — Café déjà vu!") == "obavlenie-cafe-deja-vu")
        #expect(TranscriptExporter.slug("  --Hello__World--  ") == "hello-world")
    }

    @Test func slugFallbackAndLimit() {
        #expect(TranscriptExporter.slug(nil) == "meeting")
        #expect(TranscriptExporter.slug("") == "meeting")
        #expect(TranscriptExporter.slug("!!! ??? ///") == "meeting")
        let long = TranscriptExporter.slug(String(repeating: "ab ", count: 40))
        #expect(long.count <= 60)
        #expect(!long.hasSuffix("-"))
    }

    @Test func fileNameIsDeterministic() {
        let a = TranscriptExporter.fileName(start: start, title: "Синк")
        #expect(a == "2026-10-26-1400-sink.md")
        #expect(TranscriptExporter.fileName(start: start, title: "Синк") == a)
        #expect(TranscriptExporter.fileName(start: start, title: nil) == "2026-10-26-1400-meeting.md")
    }

    @Test func yamlEscaping() {
        #expect(TranscriptExporter.yaml("plain") == "\"plain\"")
        #expect(TranscriptExporter.yaml("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(TranscriptExporter.yaml("C:\\dir") == "\"C:\\\\dir\"")
        #expect(TranscriptExporter.yaml("a\nb\tc") == "\"a\\nb\\tc\"")
        #expect(TranscriptExporter.yaml("\u{1}") == "\"\\u0001\"")
    }

    @Test func documentHasFrontmatterThenTranscript() {
        let doc = TranscriptExporter.document(transcript: "# Sync\n\nbody\n", meetingDir: URL(fileURLWithPath: "/tmp/Meetings/2026-10-26 14-00 \"Sync\""),
                                              start: start, participants: ["Ann", "O\"Brien"])
        #expect(doc == """
            ---
            source: aviacalls
            meeting_dir: "/tmp/Meetings/2026-10-26 14-00 \\"Sync\\""
            recorded: 2026-10-26T14:00
            participants: ["Ann", "O\\"Brien"]
            ---
            # Sync

            body

            """)
    }

    @Test func directoryFromSetting() {
        #expect(TranscriptExporter.directory(from: nil) == nil)
        #expect(TranscriptExporter.directory(from: "  ") == nil)
        #expect(TranscriptExporter.directory(from: "~/Vault/00-Inbox")?.path == NSHomeDirectory() + "/Vault/00-Inbox")
    }

    @Test func exportCreatesDirAndOverwritesAtomically() throws {
        let dir = tempDir().appendingPathComponent("nested/inbox")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let info = MeetingInfo(title: "Синк", start: start, end: nil, participants: ["Ann"], myName: nil, namesRead: true, micOffset: 0, zoomOffset: 0)
        let meeting = URL(fileURLWithPath: "/tmp/m")
        let first = try TranscriptExporter.export(transcript: "v1\n", info: info, meetingDir: meeting, to: dir)
        let second = try TranscriptExporter.export(transcript: "v2\n", info: info, meetingDir: meeting, to: dir)
        #expect(first == second)
        #expect(first.lastPathComponent == "2026-10-26-1400-sink.md")
        #expect(try String(contentsOf: second, encoding: .utf8).hasSuffix("---\nv2\n"))
        // только итоговый файл, временного не осталось
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["2026-10-26-1400-sink.md"])
    }

    @Test func failedExportLeavesNoFiles() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let info = MeetingInfo(title: "X", start: start, end: nil, participants: [], myName: nil, namesRead: false, micOffset: 0, zoomOffset: 0)
        // под итоговым именем лежит непустая папка — rename не сможет её заменить
        let blocker = root.appendingPathComponent("2026-10-26-1400-x.md/keep")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try TranscriptExporter.export(transcript: "t", info: info, meetingDir: root, to: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["2026-10-26-1400-x.md"])
    }
}

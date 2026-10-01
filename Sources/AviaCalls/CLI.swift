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

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

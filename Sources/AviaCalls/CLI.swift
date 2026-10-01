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

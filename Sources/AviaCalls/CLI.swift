import ApplicationServices
import AviaCallsCore
import Foundation
import UserNotifications

enum CLI {
    /// Печатает снимок окна встречи в JSON — так снимаем фикстуры для тестов.
    static func dumpAX() {
        guard AXIsProcessTrusted() else { fail("нет доступа: Системные настройки → Конфиденциальность → Универсальный доступ") }
        let reader = ZoomReader()
        guard let snapshot = reader.read() else { fail("окно встречи Zoom не найдено; окна: \(reader.windowsSummary())") }
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

    /// Собирает транскрипт для готовой папки встречи — восстановление после падения и пересборка после улучшений.
    static func transcribe(dir: String) {
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                if !WhisperModel.isInstalled {
                    print("ставлю модель \(WhisperModel.variant) (\(WhisperModel.downloadSize))…")
                    try await WhisperModel.install { _ in }
                }
                try await Pipeline.process(dir: URL(fileURLWithPath: dir), transcriber: Transcriber())
            } catch { fail("не получилось: \(error)") }
            done.signal()
        }
        done.wait()
        print("готово: \(dir)/transcript.md")
    }

    /// Показывает пробное уведомление и печатает, разрешены ли они. Запускать бинарник внутри .app.
    static func notifyTest() {
        let center = UNUserNotificationCenter.current()
        let done = DispatchSemaphore(value: 0)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            center.getNotificationSettings { settings in
                print("уведомления: status=\(settings.authorizationStatus.rawValue) (2 — разрешены), баннеры=\(settings.alertSetting.rawValue) (2 — включены), стиль=\(settings.alertStyle.rawValue) (0 — нет, 1 — баннер, 2 — предупреждение)")
                let content = UNMutableNotificationContent()
                content.title = "AviaCalls: проверка уведомлений"
                content.body = "Так будут выглядеть сообщения о начале и конце записи."
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                    print(error.map { "не показано: \($0)" } ?? "уведомление отправлено")
                    done.signal()
                }
            }
        }
        done.wait()
    }

    /// Снимает экран N секунд, как при демонстрации, и печатает, что сохранилось. Для проверки без встречи.
    static func screenTest(seconds: Double) {
        guard ScreenGrabber.allowed else { CGRequestScreenCaptureAccess(); fail("нет разрешения «Запись экрана»: выдай его и повтори") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aviacalls-screens-\(Int(Date().timeIntervalSince1970))")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // CLI работает в главном потоке, но компилятор об этом не знает
        let grabber = MainActor.assumeIsolated { ScreenGrabber() }
        MainActor.assumeIsolated { grabber.forceDisplay = true; grabber.begin(dir: dir, start: Date()) }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let shots = MainActor.assumeIsolated { grabber.end() }
        print("папка: \(dir.path)\nсохранено кадров: \(shots.count)")
        for s in shots { print("  \(s.time.rounded()) с  \(s.path)") }
    }

    /// Тихо спрашивает ленту обновлений и печатает ответ. Запускать бинарник внутри релизной .app.
    static func updateTest() {
        let updater = MainActor.assumeIsolated { AppUpdater() }
        guard updater.isConfigured else { fail("в этой сборке нет адреса ленты обновлений (SUFeedURL/SUPublicEDKey)") }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let (checking, available) = MainActor.assumeIsolated { (updater.checking, updater.available) }
            if !checking {
                print(available.map { "доступно обновление \($0)" } ?? "обновлений нет (текущая \(updater.version))")
                return
            }
        }
        fail("лента не ответила за 30 секунд")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

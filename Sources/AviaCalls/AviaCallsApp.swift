import SwiftUI

struct AviaCallsApp: App {
    @StateObject private var recorder = RecorderController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: recorder)
        } label: {
            Image(nsImage: StatusIcon.image(recording: recorder.recording, blink: recorder.blink,
                                            trouble: recorder.problem != nil || recorder.needsAccessibility, busy: recorder.jobs > 0))
        }
        Window("Встречи", id: "meetings") {
            MeetingsView(recorder: recorder)
        }
        .defaultSize(width: 980, height: 640)
    }
}

private struct MenuContent: View {
    @ObservedObject var recorder: RecorderController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(recorder.statusText)
        if recorder.needsAccessibility { Button("Выдать доступ: Универсальный доступ…") { recorder.openAccessibilitySettings() } }
        if recorder.notificationsOff { Button("Включить уведомления о записи…") { recorder.openNotificationSettings() } }
        ModelMenuItem(recorder: recorder)
        if let problem = recorder.problem { Text(problem) }
        Divider()
        if recorder.recording { Button("Остановить запись") { recorder.stopByUser() } }
        if recorder.failedFolder != nil { Button("Повторить расшифровку") { recorder.retry() } }
        Button("Встречи…") {
            openWindow(id: "meetings")
            NSApp.activate(ignoringOtherApps: true)   // у приложения нет иконки в Dock, само окно вперёд не выйдет
        }
        Button("Открыть папку встреч") { recorder.openMeetingsFolder() }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
    }
}

/// Состояние модели распознавания: кнопка установки или ход загрузки. Когда модель стоит, ничего не показывает.
struct ModelMenuItem: View {
    @ObservedObject var recorder: RecorderController

    var body: some View {
        switch recorder.model {
        case .ready: EmptyView()
        case .missing: Button("Скачать модель распознавания (\(WhisperModel.downloadSize))…") { recorder.installModel() }
        case .downloading(let fraction): Text("Качаю модель: \(Int(fraction * 100))%")
        case .preparing: Text("Готовлю модель, пара минут…")
        case .failed(let message): Button("Модель не установилась (\(message)). Повторить") { recorder.installModel() }
        }
    }
}

/// Иконка в менюбаре: по ней видно состояние, не открывая меню.
enum StatusIcon {
    /// Запись — красный кружок, который мигает; проблема — оранжевый треугольник; расшифровка — пузырь с текстом.
    static func image(recording: Bool, blink: Bool, trouble: Bool, busy: Bool) -> NSImage {
        if trouble { return symbol("exclamationmark.triangle.fill", .systemOrange) }
        if recording { return symbol(blink ? "record.circle.fill" : "record.circle", .systemRed) }
        return symbol(busy ? "text.bubble" : "record.circle", nil)
    }

    /// Без цвета картинка шаблонная и сама подстраивается под светлый и тёмный менюбар.
    private static func symbol(_ name: String, _ color: NSColor?) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "AviaCalls") ?? NSImage()
        guard let color, let tinted = base.withSymbolConfiguration(.init(paletteColors: [color])) else {
            base.isTemplate = true
            return base
        }
        tinted.isTemplate = false
        return tinted
    }
}

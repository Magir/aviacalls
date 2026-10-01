import SwiftUI

struct AviaCallsApp: App {
    @StateObject private var recorder = RecorderController()

    var body: some Scene {
        MenuBarExtra("AviaCalls", systemImage: recorder.recording ? "record.circle.fill" : (recorder.jobs > 0 ? "text.bubble" : "record.circle")) {
            MenuContent(recorder: recorder)
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

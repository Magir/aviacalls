import AviaCallsCore
import ServiceManagement
import SwiftUI

struct AviaCallsApp: App {
    @StateObject private var recorder = RecorderController()
    @StateObject private var updater = AppUpdater()

    init() { LoginItem.enrollOnce() }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: recorder, updater: updater)
        } label: {
            Image(nsImage: StatusIcon.image(recording: recorder.recording, blink: recorder.blink,
                                            trouble: recorder.problem != nil || recorder.needsAccessibility, busy: recorder.jobs > 0))
        }
        Window("Встречи", id: "meetings") {
            MeetingsView(recorder: recorder, updater: updater)
        }
        .defaultSize(width: 980, height: 640)
        Window("Настройки обработки текста", id: "postprocessing") {
            PostprocessingSettingsView(settings: recorder.postprocessing.settings)
        }
        .defaultSize(width: 620, height: 680)
    }
}

private struct MenuContent: View {
    @ObservedObject var recorder: RecorderController
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @AppStorage("transcriptExportDir") private var exportDir = ""

    var body: some View {
        Text(recorder.statusText)
        if recorder.needsAccessibility { Button("Выдать доступ: Универсальный доступ…") { recorder.openAccessibilitySettings() } }
        if recorder.notificationsOff { Button("Включить уведомления о записи…") { recorder.openNotificationSettings() } }
        if recorder.screenCaptureOff { Button("Разрешить снимки демонстраций экрана…") { recorder.openScreenRecordingSettings() } }
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
        let exportTarget = TranscriptExporter.directory(from: exportDir)
        Toggle(exportTarget.map { "Копировать транскрипты в «\($0.lastPathComponent)»" } ?? "Копировать транскрипты в папку…",
               isOn: Binding(get: { exportTarget != nil }, set: { $0 ? chooseExportDir() : (exportDir = "") }))
        if exportTarget != nil { Button("Сменить папку…") { chooseExportDir() } }
        Button("Настройки обработки текста…") {
            openWindow(id: "postprocessing")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("Запускать при входе", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.enabled = $0 }))
        Divider()
        // проверка идёт сама (при запуске и раз в сутки); пункт появляется, только когда есть что ставить
        if let version = updater.available {
            Button("Доступно обновление \(version) — скачать и установить…") { updater.install() }
        }
        Button("Выйти") { NSApp.terminate(nil) }
    }

    /// Папка, куда Pipeline кладет копию транскрипта (например, инбокс Obsidian).
    private func chooseExportDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Куда копировать транскрипт после каждой расшифровки"
        panel.directoryURL = TranscriptExporter.directory(from: exportDir)
        NSApp.activate(ignoringOtherApps: true)   // у приложения нет иконки в Dock, без этого диалог окажется под окнами
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportDir = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Автозапуск при входе в систему (пункт «Объекты входа» в настройках macOS).
enum LoginItem {
    // status — синхронный XPC к smd на ~60 мс, а меню читает его при каждой перерисовке (мигание иконки при записи)
    private static var cached: (value: Bool, at: Date)?

    static var enabled: Bool {
        get {
            if let cached, cached.at.timeIntervalSinceNow > -5 { return cached.value }
            let value = SMAppService.mainApp.status == .enabled
            cached = (value, Date())
            return value
        }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            cached = nil
        }
    }

    /// Первый запуск из .app — встаём в автозапуск сами; дальше решает пользователь (меню или настройки macOS).
    static func enrollOnce() {
        guard Bundle.main.bundleURL.pathExtension == "app", !UserDefaults.standard.bool(forKey: "loginItemEnrolled") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemEnrolled")
        enabled = true
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

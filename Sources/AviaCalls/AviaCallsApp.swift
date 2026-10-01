import SwiftUI

struct AviaCallsApp: App {
    @StateObject private var recorder = RecorderController()

    var body: some Scene {
        MenuBarExtra("AviaCalls", systemImage: recorder.recording ? "record.circle.fill" : (recorder.jobs > 0 ? "text.bubble" : "record.circle")) {
            Text(recorder.statusText)
            if recorder.needsAccessibility { Button("Выдать доступ: Универсальный доступ…") { recorder.openAccessibilitySettings() } }
            if let problem = recorder.problem { Text(problem) }
            Divider()
            if recorder.recording { Button("Остановить запись") { recorder.stopByUser() } }
            if recorder.failedFolder != nil { Button("Повторить транскрибацию") { recorder.retry() } }
            if let folder = recorder.lastFolder { Button("Открыть последнюю встречу") { NSWorkspace.shared.open(folder) } }
            Button("Открыть папку встреч") { recorder.openMeetingsFolder() }
            Divider()
            Button("Выйти") { NSApp.terminate(nil) }
        }
    }
}

import AppKit
import ApplicationServices
import AVFoundation
import AviaCallsCore
import UserNotifications

/// Следит за Zoom и ведёт запись: встреча началась → пишем, закончилась → транскрибируем.
@MainActor
final class RecorderController: ObservableObject {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Meetings")
    static let pollInterval = 0.3
    static let endAfter = 10.0   // секунд без окна встречи — встреча закончилась

    @Published private(set) var recording = false
    @Published private(set) var jobs = 0
    @Published private(set) var lastFolder: URL?
    @Published private(set) var failedFolder: URL?
    @Published private(set) var problem: String?
    @Published private(set) var needsAccessibility = false

    private let reader = ZoomReader()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()
    private var timer: Timer?
    private var store: MeetingStore?
    private var builder = TimelineBuilder(myName: nil)
    private var info: MeetingInfo?
    private var lastSeen = Date.distantPast
    private var suppressed = false   // пользователь остановил запись или она не стартовала: ждём конца этой встречи

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // системный запрос сам добавляет приложение в список «Универсального доступа»
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        // вне .app (запуск бинарника из терминала) центр уведомлений падает
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        // ponytail: опрос Accessibility идёт в главном потоке; у приложения нет окон, подвисать нечему
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var statusText: String {
        if needsAccessibility { return "Нет доступа к окну Zoom" }
        if recording { return "Идёт запись" }
        if jobs > 0 { return "Транскрибирую…" }
        return "Жду встречу в Zoom"
    }

    func stopByUser() {
        suppressed = true
        finish(Date())
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Папки нет, пока не записана первая встреча, а несуществующую папку Finder не откроет.
    func openMeetingsFolder() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.root)
    }

    func retry() {
        guard let dir = failedFolder else { return }
        failedFolder = nil
        transcribe(dir)
    }

    private func tick() {
        needsAccessibility = !AXIsProcessTrusted()
        guard !needsAccessibility else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            problem = "Нет доступа к микрофону"
            return
        }
        let now = Date()
        guard let raw = reader.read() else {
            if now.timeIntervalSince(lastSeen) > Self.endAfter {
                suppressed = false
                if recording { finish(now) }
            }
            return
        }
        lastSeen = now
        if !recording && !suppressed { begin(now) }
        guard recording, var info, let store else { return }

        let events = builder.ingest(ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle),
                                    at: now.timeIntervalSince(info.start))
        guard !events.isEmpty else { checkZoomAudio(now, info); return }
        for e in events {
            switch e.event {
            case .title(let t): info.title = t
            case .joined(let n): if !info.participants.contains(n) { info.participants.append(n) }
            case .me(let n): UserDefaults.standard.set(n, forKey: "myName")
            default: break
            }
        }
        info.myName = builder.myName
        info.namesRead = !info.participants.isEmpty
        self.info = info
        // meeting.json пишем по ходу, чтобы после падения встречу можно было восстановить через --transcribe
        do { try store.append(events); try store.save(info: info) } catch { problem = "Не пишется на диск: \(error.localizedDescription)" }
    }

    private func begin(_ now: Date) {
        do {
            let store = try MeetingStore(root: Self.root, start: now)
            try audio.start(dir: store.dir, at: now)
            self.store = store
            builder = TimelineBuilder(myName: UserDefaults.standard.string(forKey: "myName"))
            info = MeetingInfo(title: nil, start: now, end: nil, participants: [], myName: builder.myName,
                               namesRead: false, micOffset: 0, zoomOffset: 0)
            recording = true
            problem = nil
            notify("Идёт запись встречи", "Предупреди участников, что встреча записывается.")
        } catch {
            suppressed = true
            problem = "Запись не стартовала: \(error.localizedDescription)"
        }
    }

    private func finish(_ now: Date) {
        guard recording, var info, let store else { return }
        recording = false
        let offsets = audio.stop()
        info.end = now
        info.micOffset = offsets.micOffset
        info.zoomOffset = offsets.zoomOffset
        if !info.namesRead { problem = "Имена участников не прочитаны: Zoom изменил интерфейс?" }
        try? store.save(info: info)
        let dir = (try? store.finalize(title: info.title)) ?? store.dir
        (self.store, self.info) = (nil, nil)
        lastFolder = dir
        transcribe(dir)
    }

    private func transcribe(_ dir: URL) {
        jobs += 1
        Task {
            do { try await Pipeline.process(dir: dir, transcriber: transcriber) } catch {
                failedFolder = dir
                problem = "Транскрибация упала: \(error.localizedDescription)"
            }
            jobs -= 1
        }
    }

    private func checkZoomAudio(_ now: Date, _ info: MeetingInfo) {
        if now.timeIntervalSince(info.start) > 15, !audio.zoomAlive {
            problem = "Нет звука Zoom: проверь разрешение «Запись системного звука» для AviaCalls"
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

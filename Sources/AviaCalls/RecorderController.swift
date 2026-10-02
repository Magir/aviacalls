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
    static let stallAfter = 20.0 // секунд без звука в дорожке — считаем, что запись встала (смена гарнитуры занимает до 12)

    @Published private(set) var recording = false
    @Published private(set) var jobs = 0
    @Published private(set) var lastFolder: URL?
    @Published private(set) var failedFolder: URL?
    /// Что пошло не так. Каждая новая проблема показывается всплывающим уведомлением.
    @Published private(set) var problem: String? {
        didSet { if let problem, problem != oldValue { notify("AviaCalls: проблема", problem, alarm: true) } }
    }
    /// Уведомления для приложения выключены в настройках macOS — всплывашек не будет.
    @Published private(set) var notificationsOff = false
    /// Кадр мигания иконки, пока идёт запись.
    @Published private(set) var blink = true
    @Published private(set) var needsAccessibility = false {
        didSet { if needsAccessibility && !oldValue { notify("AviaCalls не видит Zoom", "Нет доступа «Универсальный доступ»: встречи не записываются. Открой меню AviaCalls → «Выдать доступ».", alarm: true) } }
    }
    @Published private(set) var model: ModelState = WhisperModel.isInstalled ? .ready : .missing
    /// Растёт, когда на диске что-то поменялось: окно встреч по нему перечитывает список.
    @Published private(set) var libraryVersion = 0

    enum ModelState: Equatable { case missing, downloading(Double), preparing, ready, failed(String) }

    private let reader = ZoomReader()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()
    private var timer: Timer?
    private var store: MeetingStore?
    private var builder = TimelineBuilder(myName: nil)
    private var info: MeetingInfo?
    private var lastSeen = Date.distantPast
    private var lastSnapshot = Date.distantPast
    private var inFlight: Set<URL> = []
    private var audioProblem: String?
    private var ticks = 0
    private var idleTicks = 0
    private let notifications = NotificationPresenter()
    private var suppressed = false   // пользователь остановил запись или она не стартовала: ждём конца этой встречи

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // системный запрос сам добавляет приложение в список «Универсального доступа»
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        // вне .app (запуск бинарника из терминала) центр уведомлений падает
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = notifications
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                NSLog("RecorderController: уведомления %@", granted ? "разрешены" : "ЗАПРЕЩЕНЫ")
            }
        }
        // ponytail: опрос Accessibility идёт в главном потоке; у приложения нет окон, подвисать нечему
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        transcribePending()
    }

    var statusText: String {
        if needsAccessibility { return "Нет доступа к окну Zoom" }
        if recording { return "Идёт запись" }
        if jobs > 0 { return "Расшифровываю…" }
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

    /// Ставит модель распознавания и после этого расшифровывает всё, что накопилось без неё.
    func installModel() {
        guard model == .missing || { if case .failed = model { return true } else { return false } }() else { return }
        model = .downloading(0)
        Task {
            do {
                try await WhisperModel.install { [weak self] fraction in
                    Task { @MainActor in self?.model = fraction < 1 ? .downloading(fraction) : .preparing }
                }
                model = .ready
                transcribePending()
            } catch {
                model = .failed(error.localizedDescription)
            }
        }
    }

    /// Встречи со звуком, но без транскрипта: записаны без модели, или приложение закрыли до конца расшифровки.
    func transcribePending() {
        guard model == .ready else { return }
        let current = store?.dir.standardizedFileURL
        for meeting in MeetingLibrary.load(root: Self.root) where meeting.hasAudio && !meeting.hasTranscript {
            if meeting.dir.standardizedFileURL != current { transcribe(meeting.dir) }
        }
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.magir.aviacalls")!)
    }

    private func refreshNotificationState() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let off = settings.authorizationStatus == .denied || settings.alertSetting == .disabled
            Task { @MainActor in self?.notificationsOff = off }
        }
    }

    private func tick() {
        idleTicks += 1
        if idleTicks % 20 == 1 { refreshNotificationState() }   // раз в 6 секунд: пользователь мог включить их в настройках
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
        ticks += 1
        if ticks % 2 == 0 { blink.toggle() }
        checkAudio(now, info)
        saveSnapshotIfNeeded(raw, now, info, store)

        let events = builder.ingest(ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle),
                                    at: now.timeIntervalSince(info.start))
        guard !events.isEmpty else { return }
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
            audioProblem = nil
            notify("Запись началась", "Пишу встречу в Zoom. Предупреди участников, что встреча записывается.")
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
        libraryVersion += 1
        let minutes = max(1, Int(now.timeIntervalSince(info.start) / 60))
        notify("Запись закончена", "\(info.title ?? "Встреча"), \(minutes) мин. " + (model == .ready ? "Расшифровываю." : "Расшифровки не будет, пока не установлена модель."))
        transcribe(dir)
    }

    func transcribe(_ dir: URL) {
        let key = dir.standardizedFileURL
        guard !inFlight.contains(key) else { return }
        guard model == .ready else {
            problem = "Встреча записана. Расшифрую, когда будет установлена модель распознавания"
            return
        }
        inFlight.insert(key)
        jobs += 1
        Task {
            do {
                try await Pipeline.process(dir: dir, transcriber: transcriber)
                notify("Расшифровка готова", dir.lastPathComponent)
            } catch {
                failedFolder = dir
                problem = "Расшифровка не удалась (\(dir.lastPathComponent)): \(error.localizedDescription)"
            }
            inFlight.remove(key)
            jobs -= 1
            libraryVersion += 1
        }
    }

    func isTranscribing(_ dir: URL) -> Bool { inFlight.contains(dir.standardizedFileURL) }

    /// Отладка: раз в 30 секунд кладёт сырой снимок окна Zoom в папку встречи — материал для фикстур
    /// из режимов, которые не воспроизвести вдвоём (чужой показ экрана, большая галерея).
    /// Включается так: defaults write com.magir.aviacalls saveSnapshots -bool YES
    private func saveSnapshotIfNeeded(_ raw: ZoomRawSnapshot, _ now: Date, _ info: MeetingInfo, _ store: MeetingStore) {
        guard UserDefaults.standard.bool(forKey: "saveSnapshots"), now.timeIntervalSince(lastSnapshot) >= 30 else { return }
        lastSnapshot = now
        let dir = store.dir.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(format: "%05d.json", Int(now.timeIntervalSince(info.start)))
        try? JSONEncoder().encode(raw).write(to: dir.appendingPathComponent(name))
    }

    /// Следит, что обе дорожки действительно пишутся, всю встречу, а не только в начале.
    private func checkAudio(_ now: Date, _ info: MeetingInfo) {
        guard now.timeIntervalSince(info.start) > 15 else { return }
        var issue: String?
        if !audio.zoomAlive {
            issue = "Нет звука Zoom: проверь разрешение «Запись системного звука» для AviaCalls"
        } else if !audio.micAlive {
            issue = "Микрофон не пишется: проверь разрешение на микрофон для AviaCalls"
        } else if let idle = audio.zoomIdle(now), idle > Self.stallAfter {
            issue = "Звук Zoom перестал записываться"
        } else if let idle = audio.micIdle(now), idle > Self.stallAfter {
            issue = "Микрофон перестал записываться"
        }
        guard issue != audioProblem else { return }
        audioProblem = issue
        if let issue {
            problem = issue
        } else {
            problem = nil
            notify("Запись восстановилась", "Обе дорожки снова пишутся.")
        }
    }

    private func notify(_ title: String, _ body: String, alarm: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if alarm { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("RecorderController: уведомление не показано: %@", "\(error)") }
        }
    }
}

/// Показывает уведомления и тогда, когда открыто окно «Встречи»: по умолчанию macOS прячет их у активного приложения.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

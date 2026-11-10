import AppKit
import ApplicationServices
import AVFoundation
import AviaCallsCore
import Combine
import os
import UserNotifications

/// Следит за Zoom и ведёт запись: встреча началась → пишем, закончилась → транскрибируем.
@MainActor
final class RecorderController: ObservableObject {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Meetings")
    static let pollInterval = 0.3
    static let endAfter = 10.0   // секунд без окна встречи и без пункта меню «Выключить звук» — встреча закончилась
    /// NSLog из приложения в `log show` не виден. Смотреть так: log show --last 1h --predicate 'subsystem == "ru.magir.aviacalls"'
    nonisolated static let log = Logger(subsystem: "ru.magir.aviacalls", category: "recorder")
    static let stallAfter = 20.0 // секунд без звука в дорожке — считаем, что запись встала (смена гарнитуры занимает до 12)
    static let keepAfter = 60.0  // секунд записи, после которых сохраняем встречу, даже если Zoom не отдал ни участников, ни кнопку выхода
    static let speakerMarkTimeout = 300.0 // секунд встречи от трёх человек без метки говорящего — сохраняем снимок окна для разбора

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
    /// Нет разрешения «Запись экрана» — снимков демонстраций не будет, остальное работает.
    @Published private(set) var screenCaptureOff = !ScreenGrabber.allowed
    /// Кадр мигания иконки, пока идёт запись.
    @Published private(set) var blink = true
    @Published private(set) var needsAccessibility = false {
        didSet { if needsAccessibility && !oldValue { notify("AviaCalls не видит Zoom", "Нет доступа «Универсальный доступ»: встречи не записываются. Открой меню AviaCalls → «Выдать доступ».", alarm: true) } }
    }
    @Published private(set) var model: ModelState = WhisperModel.isInstalled ? .ready : .missing
    /// Растёт, когда на диске что-то поменялось: окно встреч по нему перечитывает список.
    @Published private(set) var libraryVersion = 0
    let postprocessing = PostprocessingController()
    let transcription = TranscriptionSettings()
    /// Встреча расшифрована (или расшифровка упала): самое время проверить обновления — пользователь сейчас откроет меню.
    var onProcessed: () -> Void = {}

    enum ModelState: Equatable { case missing, downloading(Double), preparing, ready, failed(String) }

    private let reader = ZoomReader()   // трогаем только из фоновой очереди zoomPolling
    private let zoomPolling = ZoomPolling()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()
    private let screens = ScreenGrabber()
    private var timer: Timer?
    private var store: MeetingStore?
    private var builder = TimelineBuilder(myName: nil)
    private var info: MeetingInfo?
    private var presence = MeetingPresence(endAfter: RecorderController.endAfter)
    private var lastSight: MeetingPresence.Sight?
    private var lastSnapshot = Date.distantPast
    private var inFlight: Set<String> = []   // URL.meetingKey
    private var audioProblem: String?
    private var askedScreenCapture = false
    private var ticks = 0
    private var idleTicks = 0
    private let notifications = NotificationPresenter()
    private var suppressed = false   // пользователь остановил запись или она не стартовала: ждём конца этой встречи
    private var confirmed = false    // это встреча, а не пустое окно до входа в неё; неподтверждённую запись не сохраняем
    private var sawSpeaker = false   // Zoom хоть раз пометил говорящего на этой встрече
    private var dumpedNoSpeaker = false
    private struct TranscriptionJob {
        let dir: URL
        let mode: TranscriptionMode
        let model: String
    }
    private var pendingTranscriptions: [TranscriptionJob] = []
    private var processingTask: Task<Void, Never>?
    private var settingsSubscriptions = Set<AnyCancellable>()
    private var lastTranscriptionMode: TranscriptionMode = .local

    init() {
        lastTranscriptionMode = transcription.mode
        transcription.onChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            if self.lastTranscriptionMode != self.transcription.mode {
                self.lastTranscriptionMode = self.transcription.mode
                self.cancelTranscriptions()
                if self.transcription.mode == .openRouter { Task { await self.transcriber.unload() } }
            }
        }
        postprocessing.settings.objectWillChange.sink { [weak self] _ in
            // objectWillChange приходит до изменения значения, проверяем ключ на следующем проходе.
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                if self.transcription.mode == .openRouter && !self.postprocessing.settings.hasAPIKey {
                    self.cancelTranscriptions()
                }
            }
        }.store(in: &settingsSubscriptions)
        postprocessing.onChange = { [weak self] in self?.libraryVersion += 1 }
        // после постобработки выгружаем вычитанную версию; если обработка не удалась — исходную
        postprocessing.onFinished = { Pipeline.export(dir: $0) }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // системный запрос сам добавляет приложение в список «Универсального доступа»
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        // вне .app (запуск бинарника из терминала) центр уведомлений падает
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = notifications
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Self.log.notice("уведомления \(granted ? "разрешены" : "ЗАПРЕЩЕНЫ", privacy: .public)")
            }
        }
        // Медленный ответ Zoom не блокирует меню и окна; пока чтение идёт, новый опрос пропускается.
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

    var transcriptionReady: Bool {
        transcription.mode == .openRouter ? postprocessing.settings.hasAPIKey : model == .ready
    }

    func canTranscribe(_ dir: URL) -> Bool {
        transcriptionReady || FileManager.default.fileExists(atPath: dir.appendingPathComponent("segments.json").path)
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

    /// Облако автоматически получает только встречи, записанные при выбранном облачном режиме.
    func transcribePending() {
        let current = store?.dir.meetingKey
        for meeting in MeetingLibrary.load(root: Self.root) where meeting.hasAudio && !meeting.hasTranscript {
            if meeting.dir.meetingKey != current { transcribe(meeting.dir, automatic: true) }
        }
    }

    func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=ru.magir.aviacalls")!)
    }

    private func refreshNotificationState() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let off = settings.authorizationStatus == .denied || settings.alertSetting == .disabled
            Task { @MainActor in if self?.notificationsOff != off { self?.notificationsOff = off } }
        }
    }

    private func tick() {
        idleTicks += 1
        // @Published шлёт objectWillChange при каждом присваивании, даже того же значения, а по нему SwiftUI
        // перестраивает меню и окно; поэтому поля ниже трогаем, только когда значение сменилось
        if idleTicks % 20 == 1 {   // раз в 6 секунд: пользователь мог включить их в настройках
            refreshNotificationState()
            if screenCaptureOff != !ScreenGrabber.allowed { screenCaptureOff.toggle() }
        }
        if needsAccessibility != !AXIsProcessTrusted() { needsAccessibility.toggle() }
        guard !needsAccessibility else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            if problem != "Нет доступа к микрофону" { problem = "Нет доступа к микрофону" }
            return
        }
        // меню смотрим только во время встречи: начать запись может лишь окно встречи
        let checkMenu = recording || suppressed
        let reader = self.reader
        zoomPolling.poll({ reader.poll(checkMenu: checkMenu) }) { [weak self] poll, now in self?.consume(poll, now) }
    }

    private func consume(_ poll: ZoomPoll, _ now: Date) {
        // Разрешения могли измениться за время чтения Accessibility.
        guard !needsAccessibility, AVCaptureDevice.authorizationStatus(for: .audio) != .denied else { return }
        let inMeeting = recording || suppressed
        if inMeeting { logSightChange(poll, now) }
        guard presence.update(poll.sight, at: now) else {
            if inMeeting {   // после конца встречи inMeeting уже false: пишется один раз
                Self.log.notice("встреча закончилась: ни окна, ни пункта меню дольше порога; последний опрос: \(poll.sight.rawValue, privacy: .public)")
            }
            lastSight = nil
            suppressed = false
            if recording { finish(now) }
            return
        }
        // пишем сразу: пока Zoom дорисовывает окно, первые слова встречи уже звучат
        if !recording && !suppressed && poll.snapshot != nil { begin(now) }
        guard recording, var info, let store else { return }
        ticks += 1
        if ticks % 2 == 0 { blink.toggle() }
        checkAudio(now, info)
        // встреча идёт, но окна не видно: пишем звук дальше, участников прочитаем, когда окно вернётся
        guard let raw = poll.snapshot else {
            confirmIfNeeded(inMeeting: false, now, info)
            return
        }
        saveSnapshotIfNeeded(raw, now, info, store)

        let snapshot = ZoomTreeParser.parse(window: raw.window, muteMenuTitle: raw.muteMenuTitle)
        screens.sharing = snapshot.sharing
        confirmIfNeeded(inMeeting: snapshot.inMeeting, now, info)
        let events = builder.ingest(snapshot, at: now.timeIntervalSince(info.start))
        if events.contains(where: { if case .speaker(.some) = $0.event { return true } else { return false } }) { sawSpeaker = true }
        // Zoom помечает говорящего на встречах от трёх человек. Если метки долго нет, сохраняем сырой снимок окна:
        // по нему видно, в каком режиме Zoom её не отдаёт (у коллеги на большой встрече не пришло ни одной метки)
        if !sawSpeaker, !dumpedNoSpeaker, info.participants.count >= 3, now.timeIntervalSince(info.start) >= Self.speakerMarkTimeout {
            dumpedNoSpeaker = true
            dumpSnapshot(raw, "no-speaker-mark", store)
        }
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

    /// Встреча подтверждается участником, кнопкой выхода или минутой записи. Минута считается и без окна:
    /// иначе запись, у которой окно пропало сразу после старта, удалилась бы в finish().
    private func confirmIfNeeded(inMeeting: Bool, _ now: Date, _ info: MeetingInfo) {
        guard !confirmed, inMeeting || now.timeIntervalSince(info.start) >= Self.keepAfter else { return }
        confirmed = true
        notify("Запись началась", "Пишу встречу в Zoom. Предупреди участников, что встреча записывается.")
    }

    /// Пишет в системный лог, когда окно встречи пропадает и возвращается: по этим строкам видно, почему
    /// встреча кончилась или почему запись продолжилась без окна. Один раз на смену состояния, не каждый опрос.
    private func logSightChange(_ poll: ZoomPoll, _ now: Date) {
        guard poll.sight != lastSight else { return }
        defer { lastSight = poll.sight }
        if poll.sight == .window {
            if let gap = presence.withoutWindow(at: now) { Self.log.notice("окно встречи вернулось через \(Int(gap)) с") }
            return
        }
        let ax = poll.windowsError.map { "AX не ответил на список окон: " + ZoomReader.describe($0) } ?? "AX ответил"
        let windows = poll.windows ?? "-"
        let menu = poll.menu.map(\.description) ?? "меню не смотрели"
        let verdict = poll.sight == .menu ? "встреча идёт, запись продолжается" : poll.sight == .unknown ? "ждём ответа AX" : "ждём \(Int(Self.endAfter)) с"
        let head = lastSight == .window ? "окно встречи пропало" : "без окна встречи: \(poll.sight.rawValue)"
        Self.log.notice("\(head, privacy: .public) (\(verdict, privacy: .public)); \(ax, privacy: .public); \(menu, privacy: .public); окна: \(windows, privacy: .public)")
    }

    private func begin(_ now: Date) {
        do {
            let store = try MeetingStore(root: Self.root, start: now)
            try audio.start(dir: store.dir, at: now)
            self.store = store
            builder = TimelineBuilder(myName: UserDefaults.standard.string(forKey: "myName"))
            info = MeetingInfo(title: nil, start: now, end: nil, participants: [], myName: builder.myName,
                               namesRead: false, micOffset: 0, zoomOffset: 0,
                               glossaryPostprocessing: postprocessing.settings.automatic,
                               transcriptionMode: transcription.mode)
            recording = true
            confirmed = false
            sawSpeaker = false
            dumpedNoSpeaker = false
            problem = nil
            audioProblem = nil
            if ScreenGrabber.allowed { screens.begin(dir: store.dir, start: now) } else if !askedScreenCapture {
                askedScreenCapture = true
                CGRequestScreenCaptureAccess()   // системный запрос, один раз за запуск
            }
            Self.log.notice("запись началась: \(store.dir.lastPathComponent, privacy: .public)")
        } catch {
            Self.log.error("запись не стартовала: \(error.localizedDescription, privacy: .public)")
            suppressed = true
            problem = "Запись не стартовала: \(error.localizedDescription)"
        }
    }

    private func finish(_ now: Date) {
        guard recording, var info, let store else { return }
        recording = false
        let offsets = audio.stop()
        let shots = screens.end()
        // пустое окно до входа во встречу: короткую запись без участников выбрасываем, а не кладём в список.
        // С отладочными снимками оставляем — это материал для фикстуры
        guard confirmed || UserDefaults.standard.bool(forKey: "saveSnapshots") else {
            NSLog("RecorderController: в окне Zoom не нашлось встречи, запись удалена: %@", store.dir.lastPathComponent)
            try? FileManager.default.removeItem(at: store.dir)
            (self.store, self.info) = (nil, nil)
            return
        }
        if !shots.isEmpty { try? store.save(screenshots: shots) }
        info.end = now
        info.micOffset = offsets.micOffset
        info.zoomOffset = offsets.zoomOffset
        if !info.namesRead { problem = "Имена участников не прочитаны: Zoom изменил интерфейс?" }
        try? store.save(info: info)
        let dir = (try? store.finalize(title: info.title)) ?? store.dir
        (self.store, self.info) = (nil, nil)
        lastFolder = dir
        libraryVersion += 1
        Self.log.notice("запись закончена: \(dir.lastPathComponent, privacy: .public), \(Int(now.timeIntervalSince(info.start))) с")
        let minutes = max(1, Int(now.timeIntervalSince(info.start) / 60))
        let sameMode = (info.transcriptionMode ?? .local) == transcription.mode
        let status = sameMode && transcriptionReady ? "Расшифровываю." : "Аудио сохранено. Расшифровку можно запустить из окна «Встречи»."
        notify("Запись закончена", "\(info.title ?? "Встреча"), \(minutes) мин. " + status)
        transcribe(dir, automatic: true)
    }

    func transcribe(_ dir: URL, automatic: Bool = false) {
        let key = dir.meetingKey
        guard !inFlight.contains(key) else { return }
        let store = MeetingStore(existing: dir)
        let cached = store.loadWords() != nil
        let recordedMode = (try? store.loadInfo().transcriptionMode) ?? .local
        let mode = automatic ? recordedMode : transcription.mode
        // Старые локальные записи не уходят в облако из-за изменения общей настройки.
        if automatic && !cached && mode != transcription.mode { return }
        guard cached || (mode == .openRouter ? postprocessing.settings.hasAPIKey : model == .ready) else {
            if !automatic {
                problem = mode == .openRouter ? "Сохрани API-ключ OpenRouter в настройках расшифровки." : "Встреча записана. Установи модель или выбери OpenRouter в настройках расшифровки."
            }
            return
        }
        inFlight.insert(key)
        pendingTranscriptions.append(TranscriptionJob(dir: dir, mode: mode, model: transcription.effectiveModel))
        jobs = inFlight.count
        if processingTask == nil { processingTask = Task { await drainTranscriptions() } }
    }

    /// Одна встреча за раз: длинный архив не запускает десятки платных запросов одновременно.
    private func drainTranscriptions() async {
        defer {
            processingTask = nil
            // Ручной запуск мог прийти, пока отменённый сетевой запрос завершался.
            if !pendingTranscriptions.isEmpty { processingTask = Task { await drainTranscriptions() } }
        }
        while !pendingTranscriptions.isEmpty && !Task.isCancelled {
            let job = pendingTranscriptions.removeFirst()
            let dir = job.dir
            do {
                var configuration = TranscriptionConfiguration.local
                if MeetingStore(existing: dir).loadWords() == nil && job.mode == .openRouter {
                    configuration = TranscriptionConfiguration(mode: .openRouter, key: try await postprocessing.settings.apiKey(),
                                                               model: job.model, language: UserDefaults.standard.string(forKey: "whisperLanguage"))
                }
                try Task.checkCancellation()
                try await Pipeline.process(dir: dir, transcriber: transcriber, configuration: configuration)
                notify("Расшифровка готова", dir.lastPathComponent)
                if failedFolder?.meetingKey == dir.meetingKey { failedFolder = nil }
                problem = nil
                // с автоматической постобработкой выгрузка ждёт вычитанную версию (onFinished), иначе выгружаем сразу
                if !postprocessing.enqueue(dir, automatic: true) { Pipeline.export(dir: dir) }
            } catch {
                failedFolder = dir
                problem = Task.isCancelled ? "Расшифровка остановлена. Аудио и готовые части сохранены."
                    : "Расшифровка не удалась (\(dir.lastPathComponent)): \(error.localizedDescription)"
                // Ошибка ключа, лимита или модели затронет всю очередь. Не отправляем следующие встречи вслепую.
                if error is OpenRouterTranscriber.Failure {
                    for pending in pendingTranscriptions { inFlight.remove(pending.dir.meetingKey) }
                    pendingTranscriptions.removeAll()
                }
            }
            inFlight.remove(dir.meetingKey)
            jobs = inFlight.count
            libraryVersion += 1
            onProcessed()
        }
    }

    private func cancelTranscriptions() {
        for job in pendingTranscriptions { inFlight.remove(job.dir.meetingKey) }
        pendingTranscriptions.removeAll()
        jobs = inFlight.count
        processingTask?.cancel()
    }

    func isTranscribing(_ dir: URL) -> Bool { inFlight.contains(dir.meetingKey) }

    /// Отладка: раз в 30 секунд кладёт сырой снимок окна Zoom в папку встречи — материал для фикстур
    /// из режимов, которые не воспроизвести вдвоём (чужой показ экрана, большая галерея).
    /// Включается так: defaults write ru.magir.aviacalls saveSnapshots -bool YES
    private func saveSnapshotIfNeeded(_ raw: ZoomRawSnapshot, _ now: Date, _ info: MeetingInfo, _ store: MeetingStore) {
        guard UserDefaults.standard.bool(forKey: "saveSnapshots"), now.timeIntervalSince(lastSnapshot) >= 30 else { return }
        lastSnapshot = now
        dumpSnapshot(raw, String(format: "%05d", Int(now.timeIntervalSince(info.start))), store)
    }

    private func dumpSnapshot(_ raw: ZoomRawSnapshot, _ name: String, _ store: MeetingStore) {
        let dir = store.dir.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(raw).write(to: dir.appendingPathComponent(name + ".json"))
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
            if let error { Self.log.error("уведомление не показано: \(error, privacy: .public)") }
        }
    }
}

/// Показывает уведомления и тогда, когда открыто окно «Встречи»: по умолчанию macOS прячет их у активного приложения.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

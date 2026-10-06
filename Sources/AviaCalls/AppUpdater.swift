import Foundation
import Sparkle

/// Обновления через Sparkle. Проверка тихая: на старте и раз в сутки спрашиваем ленту без окон,
/// а найденное обновление показываем пунктом в меню; установка — через стандартный диалог Sparkle.
/// Работает только в релизных сборках: CI вписывает в Info.plist адрес ленты и публичный ключ.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let interval: TimeInterval = 24 * 60 * 60

    /// Версия, которую можно поставить; nil — обновлений нет или ещё не проверяли.
    @Published private(set) var available: String?
    @Published private(set) var checking = false
    let isConfigured: Bool

    private var controller: SPUStandardUpdaterController!
    private var timer: Timer?

    override init() {
        let plist = Bundle.main.infoDictionary ?? [:]
        isConfigured = !((plist["SUFeedURL"] as? String)?.isEmpty ?? true) && !((plist["SUPublicEDKey"] as? String)?.isEmpty ?? true)
        super.init()
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Тихая проверка: только узнать, есть ли новая версия.
    func check() {
        guard isConfigured, !checking, controller.updater.canCheckForUpdates else { return }
        checking = true
        controller.updater.checkForUpdateInformation()
    }

    /// Скачать и поставить: Sparkle покажет свой диалог с прогрессом и перезапустит приложение.
    func install() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.available = version; self.checking = false }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.available = nil; self.checking = false }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in self.checking = false }
    }
}

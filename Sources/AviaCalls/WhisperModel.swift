import Foundation
import WhisperKit

/// Модель распознавания речи на диске: где лежит, стоит ли, как поставить.
enum WhisperModel {
    /// large-v3-turbo: на замере 2026-10-02 дал самый чистый русский текст. Сжатая версия на 626 МБ
    /// путала окончания и вставляла выдуманные слова, small для русского не годится.
    /// ручка: defaults write com.magir.aviacalls whisperModel <имя из argmaxinc/whisperkit-coreml без префикса openai_whisper->
    static var variant: String { UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo" }
    static let downloadSize = "1,5 ГБ"

    /// Всё своё держим в Application Support, а не в ~/Documents/huggingface, куда WhisperKit качает по умолчанию.
    static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AviaCalls")
    static var folder: URL { base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)") }
    private static var marker: URL { folder.appendingPathComponent(".installed") }

    /// Метка ставится только после полной установки: недокачанная папка не считается.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    static func config() -> WhisperKitConfig {
        WhisperKitConfig(downloadBase: base, modelFolder: folder.path, tokenizerFolder: base, verbose: false, download: false)
    }

    /// Качает модель и один раз загружает её: при первой загрузке macOS компилирует модель под этот мак
    /// (пара минут) и докачивается токенизатор. `progress`: доля загрузки 0…1, после неё — подготовка.
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(variant: "openai_whisper-\(variant)", downloadBase: base) { progress($0.fractionCompleted) }
        progress(1)
        _ = try await WhisperKit(config())
        try Data().write(to: marker)
    }
}

struct ModelMissing: LocalizedError {
    var errorDescription: String? { "Модель распознавания не установлена" }
}

import AviaCallsCore
import Combine
import Foundation

@MainActor
final class TranscriptionSettings: ObservableObject {
    @Published var mode: TranscriptionMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: "transcriptionMode")
            onChange?()
        }
    }
    @Published var model: String {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model, forKey: "openRouterTranscriptionModel")
            onChange?()
        }
    }
    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: "transcriptionMode").flatMap(TranscriptionMode.init(rawValue:)) ?? .local
        model = defaults.string(forKey: "openRouterTranscriptionModel")
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? OpenRouterTranscriber.defaultModel
    }

    /// Пустое поле возвращает модель по умолчанию, не оставляя запись без расшифровки.
    var effectiveModel: String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? OpenRouterTranscriber.defaultModel : value
    }
}

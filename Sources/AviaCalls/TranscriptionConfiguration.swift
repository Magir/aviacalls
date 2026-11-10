import AviaCallsCore
import Foundation

/// Снимок настроек на один запуск: смена модели не смешивает результаты внутри встречи.
struct TranscriptionConfiguration: Sendable {
    let mode: TranscriptionMode
    var key = ""
    var model = OpenRouterTranscriber.defaultModel
    var language: String?
    static let local = Self(mode: .local)
}

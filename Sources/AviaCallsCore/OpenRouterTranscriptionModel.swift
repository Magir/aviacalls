import Foundation

/// STT-модель в списке настроек.
public struct OpenRouterTranscriptionModel: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    /// Каталог публичный, ключ не нужен. Есть ли у модели таймкоды слов, он не сообщает, поэтому список не фильтруем.
    public static let catalog = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=transcription")!
    /// Список без сети: модели, проверенные с запросом AviaCalls.
    public static let offline = [
        Self(id: "elevenlabs/scribe-v2", name: "ElevenLabs: Scribe v2"),
        Self(id: OpenRouterTranscriber.defaultModel, name: "OpenAI: Whisper Large V3 Turbo"),
    ]

    public static func decode(_ data: Data) throws -> [Self] {
        try JSONDecoder().decode(Catalog.self, from: data).data
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Выбранная модель остаётся в списке, даже если каталог её не знает: иначе Picker показал бы пустоту.
    public static func options(_ catalog: [Self], selected: String) -> [Self] {
        let list = catalog.isEmpty ? offline : catalog
        return list.contains { $0.id == selected } ? list : [Self(id: selected, name: selected)] + list
    }

    private struct Catalog: Decodable { let data: [OpenRouterTranscriptionModel] }
}

import Foundation
import Testing
@testable import AviaCallsCore

struct OpenRouterTranscriptionModelTests {
    private typealias Model = OpenRouterTranscriptionModel

    @Test func decodesCatalogSortedByName() throws {
        let json = #"{"data":[{"id":"openai/whisper-1","name":"OpenAI: Whisper","pricing":{}},{"id":"elevenlabs/scribe-v2","name":"ElevenLabs: Scribe v2"}]}"#
        #expect(try Model.decode(Data(json.utf8)).map(\.id) == ["elevenlabs/scribe-v2", "openai/whisper-1"])
        #expect(throws: (any Error).self) { try Model.decode(Data(#"{"error":"nope"}"#.utf8)) }
    }

    @Test func optionsWorkOfflineAndKeepSelectedModel() {
        #expect(Model.offline.contains { $0.id == OpenRouterTranscriber.defaultModel })
        #expect(Model.options([], selected: OpenRouterTranscriber.defaultModel) == Model.offline)
        let catalog = [Model(id: "a/b", name: "B")]
        #expect(Model.options(catalog, selected: "a/b") == catalog)
        #expect(Model.options(catalog, selected: "old/model") == [Model(id: "old/model", name: "old/model")] + catalog)
    }
}

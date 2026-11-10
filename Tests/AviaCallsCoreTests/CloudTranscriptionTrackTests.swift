import AVFoundation
import Foundation
import Testing
@testable import AviaCallsCore

struct CloudTranscriptionTrackTests {
    @Test func overlappingChunksOwnEachWordOnceAndKeepTrackOffset() throws {
        let chunks = TranscriptionAudioChunk.plan(duration: 241)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.end - $0.start <= 122 })
        let absolute = [Word(start: 119.8, end: 120.2, text: "граница"), Word(start: 239.8, end: 240.2, text: "дальше")]
        let placed = chunks.flatMap { chunk in
            chunk.place(absolute.filter { $0.start >= chunk.start && $0.end <= chunk.end }
                .map { Word(start: $0.start - chunk.start, end: $0.end - chunk.start, text: $0.text) }, offset: 2.5)
        }
        #expect(placed.count == 2)
        #expect(placed.map(\.text) == ["граница", "дальше"])
        #expect(abs(placed[0].start - 122.3) < 0.00001)
        #expect(TranscriptionAudioChunk.plan(duration: 0).isEmpty)
        #expect(TranscriptionAudioChunk.plan(duration: .infinity).isEmpty)
    }

    @Test func wavChunkCanBeReadWithoutAnyLocalModel() throws {
        let fixture = try Fixture(seconds: 2)
        defer { fixture.remove() }
        let reader = try TranscriptionAudioReader(url: fixture.audio)
        let data = try reader.wav(start: 0.5, end: 1.5)
        #expect(data.count == 44 + 16000 * 2)
        let wav = fixture.dir.appendingPathComponent("chunk.wav")
        try data.write(to: wav)
        let decoded = try AVAudioFile(forReading: wav)
        #expect(decoded.length == 16000)
        #expect(decoded.processingFormat.sampleRate == 16000)
        #expect(decoded.processingFormat.channelCount == 1)
    }

    @Test func retryKeepsSuccessfulChunksAndCostAcrossTrackFailure() async throws {
        let fixture = try Fixture(seconds: 121)
        defer { fixture.remove() }
        let calls = Calls()
        let first = CloudTranscriptionTrack { _, _ in
            let n = await calls.next()
            if n == 2 { throw URLError(.timedOut) }
            return .init(words: [Word(start: 1, end: 1.1, text: "первая")], cost: 0.01)
        }
        await #expect(throws: URLError.self) {
            try await first.words(audio: fixture.audio, offset: 3, levels: fixture.levels,
                                  model: "test/stt", language: nil, store: fixture.store)
        }
        let resumed = CloudTranscriptionTrack { _, _ in
            _ = await calls.next()
            return .init(words: [Word(start: 1.2, end: 1.5, text: "вторая")], cost: 0.02)
        }
        let words = try await resumed.words(audio: fixture.audio, offset: 3, levels: fixture.levels,
                                            model: "test/stt", language: nil, store: fixture.store)
        #expect(await calls.value == 3)
        #expect(words.map(\.text) == ["первая", "вторая"])
        #expect(words[0].start == 4)
        #expect(abs(words[1].start - 123.2) < 0.00001)
        let cost = try #require(fixture.store.loadTranscriptionCost())
        #expect(abs(cost.amount - 0.03) < 0.000001)
        #expect(cost.isLowerBound)
        _ = try await resumed.words(audio: fixture.audio, offset: 3, levels: fixture.levels,
                                    model: "test/stt", language: nil, store: fixture.store)
        #expect(await calls.value == 3)
    }

    @Test func changedModelAndChangedAudioDoNotReusePaidResults() async throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let calls = Calls()
        let cloud = CloudTranscriptionTrack { _, _ in
            _ = await calls.next()
            return .init(words: [Word(start: 0, end: 0.5, text: "тест")], cost: 0.01)
        }
        for model in ["first", "first", "second"] {
            _ = try await cloud.words(audio: fixture.audio, offset: 0, levels: fixture.levels, model: model,
                                      language: nil, store: fixture.store)
        }
        #expect(await calls.value == 2)
        try fixture.writeAudio(value: 2000)
        _ = try await cloud.words(audio: fixture.audio, offset: 0, levels: fixture.levels, model: "second",
                                  language: nil, store: fixture.store)
        #expect(await calls.value == 3)
    }

    @Test func silenceDoesNotUploadOrRequireAPIKey() async throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let cloud = CloudTranscriptionTrack { _, _ in
            Issue.record("Silent audio must not be uploaded")
            throw URLError(.badURL)
        }
        let words = try await cloud.words(audio: fixture.audio, offset: 0, levels: [Float](repeating: 0, count: 10),
                                          model: "test", language: nil, store: fixture.store)
        #expect(words.isEmpty)
        #expect(fixture.store.loadTranscriptionCost() == nil)
    }

    @Test func microphoneMutedInZoomDoesNotLeaveTheComputer() async throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        try fixture.store.append([TimedEvent(t: 0.2, event: .myMic(on: false))])
        let cloud = CloudTranscriptionTrack { _, _ in
            Issue.record("Muted microphone must not be uploaded")
            throw URLError(.badURL)
        }
        #expect(try await cloud.words(audio: fixture.audio, offset: 0, levels: fixture.levels,
                                      model: "test", language: nil, store: fixture.store).isEmpty)
    }

    @Test func mutedSamplesAreZeroedWithoutChangingWordTimeScale() throws {
        let fixture = try Fixture(seconds: 2)
        defer { fixture.remove() }
        let reader = try TranscriptionAudioReader(url: fixture.audio)
        let data = try reader.wav(start: 0.5, end: 1.5, muted: [.init(start: 0.8, end: 1.2)])
        #expect(data.count == 44 + 16000 * 2)
        let samples = data.dropFirst(44)
        #expect(samples.prefix(100).contains { $0 != 0 })
        let lower = 44 + 4800 * 2, upper = 44 + 11200 * 2
        #expect(data[lower..<upper].allSatisfy { $0 == 0 })
        #expect(samples.suffix(100).contains { $0 != 0 })
    }

    private actor Calls {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    private struct Fixture {
        let dir: URL
        let seconds: Int
        var audio: URL { dir.appendingPathComponent("mic.caf") }
        var store: MeetingStore { MeetingStore(existing: dir) }
        var levels: [Float] { [Float](repeating: 0.05, count: seconds * 10) }
        init(seconds: Int) throws {
            self.seconds = seconds
            dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeAudio(value: 1000)
        }
        func writeAudio(value: Int16) throws {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            let file = try AVAudioFile(forWriting: audio, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for i in 0..<16000 { buffer.int16ChannelData![0][i] = value }
            for _ in 0..<seconds { try file.write(from: buffer) }
        }
        func remove() { try? FileManager.default.removeItem(at: dir) }
    }
}

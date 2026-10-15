import AviaCallsCore
import Combine
import Foundation

/// Отдельная очередь: сеть не задерживает запись и локальную расшифровку других встреч.
@MainActor
final class PostprocessingController: ObservableObject {
    let settings: PostprocessingSettings
    var onChange: () -> Void = {}
    @Published private(set) var statuses: [URL: Status] = [:]
    @Published private(set) var costs: [URL: PostprocessingCost] = [:]
    private var queue: [(dir: URL, automatic: Bool)] = []
    private var running = false
    private let processor: OpenRouterPostprocessor

    enum Status: Equatable { case queued, processing, done, failed(String) }

    init(settings: PostprocessingSettings? = nil, processor: OpenRouterPostprocessor = OpenRouterPostprocessor()) {
        self.settings = settings ?? PostprocessingSettings()
        self.processor = processor
    }

    func isBusy(_ dir: URL) -> Bool {
        let status = statuses[dir.standardizedFileURL]
        return status == .queued || status == .processing
    }

    func enqueue(_ dir: URL, automatic: Bool = false) {
        let dir = dir.standardizedFileURL
        guard !isBusy(dir) else { return }
        if automatic && !settings.automatic { return }
        queue.append((dir, automatic))
        statuses[dir] = .queued
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        defer { running = false }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            if job.automatic && !settings.automatic { statuses.removeValue(forKey: job.dir); continue }
            statuses[job.dir] = .processing
            do {
                if job.automatic {
                    guard await Self.needsAutomaticProcessing(job.dir) else {
                        statuses.removeValue(forKey: job.dir)
                        continue
                    }
                }
                let config = try await settings.configuration()
                let settings = self.settings
                try await Self.process(job.dir, config: config, processor: processor, onRequestStart: {
                    let total = try await Self.beginRequest(in: job.dir)
                    await MainActor.run { self.costs[job.dir] = total }
                }, onCost: { cost in
                    let total = try await Self.recordCost(cost, in: job.dir)
                    await MainActor.run { self.costs[job.dir] = total }
                }) {
                    await MainActor.run { !job.automatic || settings.automatic }
                }
                statuses[job.dir] = .done
                onChange()
            } catch is CancellationError {
                statuses.removeValue(forKey: job.dir)
            } catch {
                statuses[job.dir] = .failed(error.localizedDescription)
            }
        }
    }

    private nonisolated static func needsAutomaticProcessing(_ dir: URL) async -> Bool {
        (try? MeetingStore(existing: dir).loadInfo().glossaryPostprocessing) == true && TranscriptCorrection.currentURL(in: dir) == nil
    }

    private nonisolated static func recordCost(_ cost: Double?, in dir: URL) async throws -> PostprocessingCost? {
        let store = MeetingStore(existing: dir)
        try store.recordPostprocessingCost(cost)
        return try store.loadInfo().postprocessingCost
    }

    private nonisolated static func beginRequest(in dir: URL) async throws -> PostprocessingCost? {
        let store = MeetingStore(existing: dir)
        try store.beginPostprocessingRequest()
        return try store.loadInfo().postprocessingCost
    }

    private nonisolated static func process(_ dir: URL,
                                           config: (glossary: Glossary, key: String, model: String, instruction: String),
                                           processor: OpenRouterPostprocessor,
                                           onRequestStart: @escaping @Sendable () async throws -> Void,
                                           onCost: @escaping @Sendable (Double?) async throws -> Void,
                                           maySend: @escaping @Sendable () async -> Bool) async throws {
        let originalURL = dir.appendingPathComponent("transcript.md")
        let source = try String(contentsOf: originalURL, encoding: .utf8)
        try MeetingStore(existing: dir).preparePostprocessingInfo()
        let corrected = try await processor.correct(source: source, glossary: config.glossary,
                                                                    apiKey: config.key, model: config.model, instruction: config.instruction,
                                                                    speakers: TranscriptCorrection.loadSpeakers(source: source, in: dir),
                                                                    onRequestStart: onRequestStart, onCost: onCost, maySend: maySend)
        // Локальный транскрипт мог быть пересобран, пока шёл сетевой запрос.
        guard try String(contentsOf: originalURL, encoding: .utf8) == source else { throw ChangedTranscript() }
        try TranscriptCorrection.save(corrected, source: source, in: dir)
    }

    private struct ChangedTranscript: LocalizedError {
        var errorDescription: String? { "Исходная расшифровка изменилась во время обработки. Запусти обработку ещё раз." }
    }
}

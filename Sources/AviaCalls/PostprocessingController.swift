import AviaCallsCore
import Combine
import Foundation

/// Отдельная очередь: сеть не задерживает запись и локальную расшифровку других встреч.
@MainActor
final class PostprocessingController: ObservableObject {
    let settings: PostprocessingSettings
    var onChange: () -> Void = {}
    /// Задача ушла из очереди с любым исходом: готово, ошибка, отмена или обработка не понадобилась.
    var onFinished: (URL) -> Void = { _ in }
    // ключ — URL.meetingKey: одна и та же папка приходит то со слэшем на конце, то без
    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var costs: [String: PostprocessingCost] = [:]
    private var queue: [(dir: URL, automatic: Bool)] = []
    private var running = false
    private let processor: OpenRouterPostprocessor

    enum Status: Equatable { case queued, processing, done, failed(String) }

    init(settings: PostprocessingSettings? = nil, processor: OpenRouterPostprocessor = OpenRouterPostprocessor()) {
        self.settings = settings ?? PostprocessingSettings()
        self.processor = processor
    }

    func status(_ dir: URL) -> Status? { statuses[dir.meetingKey] }
    func cost(_ dir: URL) -> PostprocessingCost? { costs[dir.meetingKey] }

    func isBusy(_ dir: URL) -> Bool {
        let status = status(dir)
        return status == .queued || status == .processing
    }

    /// true — встреча в очереди (поставлена сейчас или уже стояла): onFinished для неё ещё придёт.
    @discardableResult
    func enqueue(_ dir: URL, automatic: Bool = false) -> Bool {
        guard !isBusy(dir) else { return true }
        if automatic && !settings.automatic { return false }
        queue.append((dir, automatic))
        statuses[dir.meetingKey] = .queued
        guard !running else { return true }
        running = true
        Task { await drain() }
        return true
    }

    private func drain() async {
        defer { running = false }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let key = job.dir.meetingKey
            defer { onFinished(job.dir) }
            if job.automatic && !settings.automatic { statuses.removeValue(forKey: key); continue }
            statuses[key] = .processing
            do {
                if job.automatic {
                    guard await Self.needsAutomaticProcessing(job.dir) else {
                        statuses.removeValue(forKey: key)
                        continue
                    }
                }
                let config = try await settings.configuration()
                let settings = self.settings
                let dir = job.dir
                try await Self.process(job.dir, config: config, processor: processor, onRequestStart: {
                    let total = try MeetingStore(existing: dir).updatePostprocessingCost { $0.beginRequest() }
                    await MainActor.run { self.costs[key] = total }
                }, onCost: { cost in
                    let total = try MeetingStore(existing: dir).updatePostprocessingCost { $0.add(cost) }
                    await MainActor.run { self.costs[key] = total }
                }) {
                    await MainActor.run { !job.automatic || settings.automatic }
                }
                statuses[key] = .done
                onChange()
            } catch is CancellationError {
                statuses.removeValue(forKey: key)
            } catch {
                statuses[key] = .failed(error.localizedDescription)
            }
        }
    }

    private nonisolated static func needsAutomaticProcessing(_ dir: URL) async -> Bool {
        (try? MeetingStore(existing: dir).loadInfo().glossaryPostprocessing) == true && TranscriptCorrection.currentURL(in: dir) == nil
    }

    private nonisolated static func process(_ dir: URL,
                                           config: (glossary: Glossary, key: String, model: String, instruction: String),
                                           processor: OpenRouterPostprocessor,
                                           onRequestStart: @escaping @Sendable () async throws -> Void,
                                           onCost: @escaping @Sendable (Double?) async throws -> Void,
                                           maySend: @escaping @Sendable () async -> Bool) async throws {
        let originalURL = dir.appendingPathComponent("transcript.md")
        let source = try String(contentsOf: originalURL, encoding: .utf8)
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

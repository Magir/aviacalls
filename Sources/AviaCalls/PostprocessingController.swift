import AviaCallsCore
import Combine
import Foundation

/// Отдельная очередь: сеть не задерживает запись и локальную расшифровку других встреч.
@MainActor
final class PostprocessingController: ObservableObject {
    let settings: PostprocessingSettings
    var onChange: () -> Void = {}
    @Published private(set) var statuses: [URL: Status] = [:]
    private var queue: [(dir: URL, automatic: Bool)] = []
    private var running = false

    enum Status: Equatable { case queued, processing, done, failed(String) }

    init(settings: PostprocessingSettings? = nil) { self.settings = settings ?? PostprocessingSettings() }

    func isBusy(_ dir: URL) -> Bool {
        let status = statuses[dir.standardizedFileURL]
        return status == .queued || status == .processing
    }

    func enqueue(_ dir: URL, automatic: Bool = false) {
        let dir = dir.standardizedFileURL
        guard !isBusy(dir) else { return }
        if automatic {
            guard settings.automatic,
                  (try? MeetingStore(existing: dir).loadInfo().glossaryPostprocessing) == true,
                  TranscriptCorrection.currentURL(in: dir) == nil else { return }
        }
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
                let config = try settings.configuration()
                let originalURL = job.dir.appendingPathComponent("transcript.md")
                let source = try String(contentsOf: originalURL, encoding: .utf8)
                let settings = self.settings
                let corrected = try await OpenRouterPostprocessor().correct(source: source, glossary: config.glossary,
                                                                            apiKey: config.key, model: config.model) {
                    await MainActor.run { !job.automatic || settings.automatic }
                }
                // Локальный транскрипт мог быть пересобран, пока шёл сетевой запрос.
                guard try String(contentsOf: originalURL, encoding: .utf8) == source else { throw ChangedTranscript() }
                try TranscriptCorrection.save(corrected, source: source, in: job.dir)
                statuses[job.dir] = .done
                onChange()
            } catch is CancellationError {
                statuses.removeValue(forKey: job.dir)
            } catch {
                statuses[job.dir] = .failed(error.localizedDescription)
            }
        }
    }

    private struct ChangedTranscript: LocalizedError {
        var errorDescription: String? { "Исходная расшифровка изменилась во время обработки. Запусти обработку ещё раз." }
    }
}

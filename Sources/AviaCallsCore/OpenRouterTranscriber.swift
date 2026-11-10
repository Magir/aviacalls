import Foundation

/// Распознаёт один ограниченный кусок аудио. Нарезка, сохранение прогресса и подпись говорящих — у вызывающего кода.
public struct OpenRouterTranscriber: Sendable {
    public static let defaultModel = "openai/whisper-large-v3-turbo"
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias Sleep = @Sendable (Double) async throws -> Void
    private let transport: Transport
    private let sleep: Sleep

    public struct Result: Equatable, Sendable {
        /// Времена относительно переданного куска, без смещения дорожки или встречи.
        public let words: [Word]
        public let cost: Double?
        public init(words: [Word], cost: Double?) { self.words = words; self.cost = cost }
    }

    public init(session: URLSession? = nil) {
        let session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 120
            return URLSession(configuration: configuration)
        }()
        self.init(transport: { try await session.data(for: $0) })
    }

    public init(transport: @escaping Transport, sleep: @escaping Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }) {
        self.transport = transport
        self.sleep = sleep
    }

    public func transcribe(audio: Data, format: String, key: String, model: String,
                           language: String? = nil, duration: Double) async throws -> Result {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !audio.isEmpty, !key.isEmpty, !model.isEmpty, !format.isEmpty,
              duration.isFinite, duration > 0 else { throw Failure(.configuration, cost: 0) }
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio.base64EncodedString(), "format": format],
            "response_format": "verbose_json",
            "timestamp_granularities": ["word", "segment"],
            "provider": ["zdr": true, "data_collection": "deny"]
        ]
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            body["language"] = language
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var retriedRateLimit = false
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do { (data, response) = try await transport(request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if error.code == .timedOut { throw Failure(.timeout, cost: nil) }
                throw Failure(.network, cost: Self.notSent.contains(error.code) ? 0 : nil)
            } catch { throw Failure(.network, cost: nil) }
            guard let http = response as? HTTPURLResponse else { throw Failure(.response, cost: nil) }
            // Один короткий повтор допустим только при явном отказе по лимиту, до выполнения модели.
            // Долгий Retry-After не сокращаем: пользователь повторит позже. Timeout/5xx никогда не повторяем вслепую.
            if http.statusCode == 429, !retriedRateLimit, let delay = Self.retryDelay(http) {
                retriedRateLimit = true
                try await sleep(delay)
                continue
            }
            guard http.statusCode == 200 else {
                throw Failure(.http(http.statusCode), cost: Self.rejected.contains(http.statusCode) ? 0 : nil)
            }
            return try Self.decode(data, duration: duration)
        }
    }

    private static func retryDelay(_ response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return 1 }
        guard let delay = Double(value), delay.isFinite, delay >= 0, delay <= 2 else { return nil }
        return delay
    }

    private static func decode(_ data: Data, duration: Double) throws -> Result {
        let decoder = JSONDecoder()
        // Стоимость читаем отдельно: испорченный текст не отменяет уже оплаченный запрос.
        let cost = (try? decoder.decode(UsageEnvelope.self, from: data).usage?.cost)
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard let response = try? decoder.decode(Response.self, from: data),
              response.text != nil || response.words != nil || response.segments != nil else {
            throw Failure(.response, cost: cost)
        }
        let hasText = !(response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (response.segments ?? []).contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let supplied = response.words, !supplied.isEmpty else {
            if hasText { throw Failure(.missingWordTimestamps, cost: cost) }
            return Result(words: [], cost: cost)
        }
        var words: [Word] = []
        for word in supplied {
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper округляет конец последнего слова и может выйти за длину куска на доли секунды. Такой ответ
            // повторялся бы при каждой попытке, и оплаченный кусок никогда бы не сохранился — поэтому обрезаем.
            guard !text.isEmpty, word.start.isFinite, word.end.isFinite,
                  word.start >= 0, word.end >= word.start, word.start <= duration, word.end <= duration + Self.endSlack else {
                throw Failure(.invalidWordTimestamps, cost: cost)
            }
            words.append(Word(start: word.start, end: min(word.end, duration), text: text, p: nil))
        }
        // Сохраняем порядок ответа при одинаковом начале: это бывает у пунктуации и одновременной речи.
        let sorted = words.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        return Result(words: sorted, cost: cost)
    }

    private struct UsageEnvelope: Decodable { let usage: Usage? }
    private struct Usage: Decodable { let cost: Double? }
    private struct Response: Decodable {
        let text: String?
        let words: [TimedWord]?
        let segments: [Segment]?
    }
    private struct TimedWord: Decodable { let word: String; let start: Double; let end: Double }
    private struct Segment: Decodable { let text: String }
    static let endSlack = 1.0
    private static let notSent: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
    private static let rejected: Set<Int> = [400, 401, 402, 403, 404, 413, 422, 429]

    public struct Failure: LocalizedError, Sendable {
        public enum Reason: Equatable, Sendable {
            case configuration, network, timeout, response, missingWordTimestamps, invalidWordTimestamps, http(Int)
        }
        public let reason: Reason
        /// nil — цена неизвестна, в том числе при потере ответа уже отправленного запроса.
        public let cost: Double?
        fileprivate init(_ reason: Reason, cost: Double?) { self.reason = reason; self.cost = cost }
        public var errorDescription: String? {
            switch reason {
            case .configuration: return "Для облачной расшифровки нужны аудио, его длительность, API-ключ и STT-модель OpenRouter."
            case .network: return "Не удалось связаться с OpenRouter. Проверь соединение и повтори расшифровку."
            case .timeout: return "OpenRouter не успел расшифровать фрагмент. Его стоимость неизвестна; повтори позже или уменьши длину фрагмента."
            case .response: return "OpenRouter вернул некорректную расшифровку. Результат не сохранён."
            case .missingWordTimestamps: return "STT-модель не вернула таймкоды слов. Выбери модель с verbose_json и word timestamps: без них нельзя сохранить подписи говорящих."
            case .invalidWordTimestamps: return "OpenRouter вернул некорректные таймкоды слов. Результат не сохранён; попробуй другую STT-модель."
            case .http(400), .http(422): return "OpenRouter отклонил параметры распознавания. Проверь, что STT-модель поддерживает verbose_json и word timestamps."
            case .http(401): return "OpenRouter не принял API-ключ. Обнови его в настройках."
            case .http(402): return "На счёте OpenRouter недостаточно средств для расшифровки."
            case .http(403): return "OpenRouter запретил запрос. Проверь доступ ключа к STT-модели и настройки данных."
            case .http(404): return "STT-модель или подходящий провайдер с Zero Data Retention не найдены. Выбери другую модель."
            case .http(413): return "Аудиофрагмент слишком большой для OpenRouter. Уменьши длину фрагмента."
            case .http(429): return "Достигнут лимит запросов OpenRouter. Повтори расшифровку позже."
            case .http(let status): return "Ошибка OpenRouter при расшифровке (HTTP \(status)). Повтори позже; стоимость неудачного запроса может быть неизвестна."
            }
        }
    }
}

import Foundation
import Testing
@testable import AviaCallsCore

@Suite(.serialized) struct OpenRouterPostprocessorTests {
    private let glossary = try! Glossary(csv: "term,description\nОрбита,вымышленный продукт\n")
    private let source = "# Закрытый заголовок\nУчастники: Иван\n\n[00:00:01] Иван: Открыли Арбиту.\n[00:00:02] (экран): screens/test.jpg\n"

    @Test func sendsOnlySpeechAndGlossaryWithPrivacyConstraints() async throws {
        let client = makeClient { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let provider = try #require(body["provider"] as? [String: Any])
            #expect(provider["zdr"] as? Bool == true)
            #expect(provider["data_collection"] as? String == "deny")
            #expect(provider["require_parameters"] as? Bool == true)
            let format = try #require(body["response_format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["role"] as? String == "system")
            #expect(messages.first?["content"] as? String == OpenRouterPostprocessor.systemInstruction(for: OpenRouterPostprocessor.defaultInstruction))
            let input = try #require(messages.last?["content"] as? String)
            #expect(!input.contains("Закрытый заголовок"))
            #expect(!input.contains("Иван"))
            #expect(!input.contains("00:00:01"))
            #expect(!input.contains("screens/test.jpg"))
            let glossaryBlocks = try #require(messages[1]["content"] as? [[String: Any]])
            let glossaryText = try #require(glossaryBlocks.first?["text"] as? String)
            #expect(glossaryText.contains("вымышленный продукт"))
            #expect(!input.contains("вымышленный продукт"))
            return (200, try response(segments: [["id": 0, "text": "Открыли Орбиту."]]))
        }
        let result = try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model")
        #expect(result == source.replacingOccurrences(of: "Арбиту", with: "Орбиту"))
        #expect(StubProtocol.count == 1)
    }

    @Test func sendsCustomInstructionWithoutChangingSchemaOrPrivacyConstraints() async throws {
        let instruction = "Исправляй только названия продуктов из glossary."
        let client = makeClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let provider = try #require(body["provider"] as? [String: Any])
            #expect(provider["zdr"] as? Bool == true)
            #expect(provider["data_collection"] as? String == "deny")
            #expect(provider["require_parameters"] as? Bool == true)
            let format = try #require(body["response_format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.count == 3)
            #expect(messages.first?["role"] as? String == "system")
            #expect(messages.first?["content"] as? String == OpenRouterPostprocessor.systemInstruction(for: instruction))
            return (200, try echo(request))
        }
        #expect(try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", instruction: instruction) == source)
    }

    @Test func blankInstructionFallsBackToDefault() async throws {
        let client = makeClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["content"] as? String == OpenRouterPostprocessor.systemInstruction(for: OpenRouterPostprocessor.defaultInstruction))
            return (200, try echo(request))
        }
        #expect(try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", instruction: " \n\t ") == source)
    }

    @Test func emptySpeechDoesNotSendAnything() async throws {
        let client = makeClient { request in Issue.record("Unexpected request"); return (500, Data()) }
        let empty = "# Встреча\n[00:00:02] (экран): screens/test.jpg\n"
        #expect(try await client.correct(source: empty, glossary: glossary, apiKey: "test-key", model: "test/model") == empty)
        #expect(StubProtocol.count == 0)
    }

    @Test func rejectsTruncatedAndMalformedResponses() async throws {
        let invalid = [
            try response(segments: [], finish: "length"),
            Data("{\"choices\":[]}".utf8),
            Data("{\"error\":{\"message\":\"private provider response\"}}".utf8),
            Data("not json".utf8),
            try response(content: "not json"),
            try response(content: "{\"segments\":[{\"id\":true,\"text\":\"текст\"}]}")
        ]
        for payload in invalid {
            let client = makeClient { request in (200, payload) }
            await #expect(throws: OpenRouterPostprocessor.Failure.self) {
                try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model")
            }
            #expect(StubProtocol.count == 1)
        }
    }

    @Test func failureInLaterBatchDoesNotReturnPartialResultOrRetry() async throws {
        let long = "[00:00:01] A: " + String(repeating: "а ", count: 1500) + "\n[00:00:02] B: " + String(repeating: "б ", count: 1500)
        let client = makeClient { request in
            StubProtocol.count == 1 ? (200, try echo(request)) : (429, Data("private provider response".utf8))
        }
        do {
            _ = try await client.correct(source: long, glossary: glossary, apiKey: "test-key", model: "test/model")
            Issue.record("Expected rate limit failure")
        } catch {
            #expect(error.localizedDescription.contains("лимит"))
            #expect(!error.localizedDescription.contains("private provider response"))
        }
        #expect(StubProtocol.count == 2)
    }

    @Test func reportsCostsForBatchesAndMarksMissingOrFailedCostsUnknown() async throws {
        let long = "[00:00:01] A: " + String(repeating: "а ", count: 1500) + "\n[00:00:02] B: " + String(repeating: "б ", count: 1500)
        let costs = Costs()
        let client = makeClient { request in
            switch StubProtocol.count {
            case 1: return (200, try echo(request, cost: 0.000123))
            default: return (429, Data())
            }
        }
        await #expect(throws: OpenRouterPostprocessor.Failure.self) {
            try await client.correct(source: long, glossary: glossary, apiKey: "test-key", model: "test/model", onCost: { await costs.add($0) })
        }
        #expect(await costs.values == [0.000123, nil])

        let noCost = Costs()
        let missing = makeClient { request in (200, try echo(request, cost: "bad")) }
        _ = try await missing.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", onCost: { await noCost.add($0) })
        #expect(await noCost.values == [nil])
    }

    @Test func startsRequestBeforeSendingAndDoesNotSendWhenStartFails() async throws {
        let events = Events()
        let client = makeClient { request in
            events.add("http")
            return (200, try echo(request))
        }
        _ = try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model",
                                     onRequestStart: { events.add("start") })
        #expect(events.values == ["start", "http"])

        let failing = makeClient { request in Issue.record("Unexpected request"); return (500, Data()) }
        await #expect(throws: StartFailure.self) {
            try await failing.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model",
                                      onRequestStart: { throw StartFailure() })
        }
        #expect(StubProtocol.count == 0)
    }

    @Test func reportsZeroAndMissingCostsAcrossSuccessfulBatches() async throws {
        let long = "[00:00:01] A: " + String(repeating: "а ", count: 1500) + "\n[00:00:02] B: " + String(repeating: "б ", count: 1500)
        let costs = Costs()
        let client = makeClient { request in
            StubProtocol.count == 1 ? (200, try echo(request, cost: 0)) : (200, try echo(request))
        }
        _ = try await client.correct(source: long, glossary: glossary, apiKey: "test-key", model: "test/model", onCost: { await costs.add($0) })
        #expect(await costs.values == [0, nil])
    }

    @Test func reportsKnownCostBeforeRejectingInvalidText() async throws {
        let costs = Costs()
        let client = makeClient { request in (200, try response(segments: [["id": 0, "text": ""]], cost: 0.25)) }
        await #expect(throws: TranscriptCorrection.ValidationError.self) {
            try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", onCost: { await costs.add($0) })
        }
        #expect(await costs.values == [0.25])
    }

    @Test func reportsCostBeforeRejectingIncompleteOrInvalidCorrectionPayload() async throws {
        let payloads = [
            try response(segments: [], finish: "length", cost: 0.1),
            try response(content: "not json", cost: 0.2),
        ]
        for (index, payload) in payloads.enumerated() {
            let costs = Costs()
            let client = makeClient { request in (200, payload) }
            await #expect(throws: OpenRouterPostprocessor.Failure.self) {
                try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", onCost: { await costs.add($0) })
            }
            #expect(await costs.values == [Double(index + 1) / 10])
        }
    }

    @Test func ignoresMalformedUsageShapeWhenCorrectionIsValid() async throws {
        let client = makeClient { request in
            var body = try JSONSerialization.jsonObject(with: echo(request)) as! [String: Any]
            body["usage"] = []
            return (200, try JSONSerialization.data(withJSONObject: body))
        }
        #expect(try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model") == source)
    }

    @Test func reportsCostWhenChoicesAreMissingOrNull() async throws {
        for choices in ["null", "[]"] {
            let costs = Costs()
            let payload = Data("{\"choices\":\(choices),\"usage\":{\"cost\":0.25}}".utf8)
            let client = makeClient { request in (200, payload) }
            await #expect(throws: OpenRouterPostprocessor.Failure.self) {
                try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", onCost: { await costs.add($0) })
            }
            #expect(await costs.values == [0.25])
        }
    }

    @Test func disablingAutomaticProcessingStopsBeforeNextBatch() async throws {
        let permission = Permission()
        let long = "[00:00:01] A: " + String(repeating: "а ", count: 1500) + "\n[00:00:02] B: " + String(repeating: "б ", count: 1500)
        let client = makeClient { request in (200, try echo(request)) }
        await #expect(throws: CancellationError.self) {
            try await client.correct(source: long, glossary: glossary, apiKey: "test-key", model: "test/model",
                                     onCost: { _ in await permission.disable() },
                                     maySend: { await permission.allowed() })
        }
        #expect(StubProtocol.count == 1)
    }

    @Test func disablingDuringRequestPreparationSendsNothingAndClearsOnlyCurrentPending() async throws {
        for unknown in [false, true] {
            let permission = Permission()
            let store = try MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), start: Date())
            try store.preparePostprocessingInfo()
            try store.recordPostprocessingCost(0.25)
            if unknown { try store.recordPostprocessingCost(nil) }
            let client = makeClient { request in Issue.record("Unexpected request"); return (500, Data()) }
            await #expect(throws: CancellationError.self) {
                try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model",
                                         onRequestStart: {
                    try store.beginPostprocessingRequest()
                    await permission.disable()
                }, onCost: { try store.recordPostprocessingCost($0) }, maySend: { await permission.allowed() })
            }
            #expect(StubProtocol.count == 0)
            #expect(try store.loadInfo().postprocessingCost == .init(amount: 0.25, isLowerBound: unknown))
        }
    }

    @Test func cancellationDuringRequestPreparationDoesNotSendOrCharge() async throws {
        let costs = Costs()
        let client = makeClient { request in Issue.record("Unexpected request"); return (500, Data()) }
        let task = Task {
            try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model",
                                     onRequestStart: { withUnsafeCurrentTask { $0?.cancel() } },
                                     onCost: { await costs.add($0) })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubProtocol.count == 0)
        #expect(await costs.values == [0])
    }

    @Test func disabledProcessingSendsNothing() async throws {
        let client = makeClient { request in Issue.record("Unexpected request"); return (500, Data()) }
        await #expect(throws: CancellationError.self) {
            try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", maySend: { false })
        }
        #expect(StubProtocol.count == 0)
    }

    @Test func invalidFirstBatchStopsBeforeMorePaidRequests() async throws {
        let long = "[00:00:01] A: " + String(repeating: "а ", count: 1500) + "\n[00:00:02] B: " + String(repeating: "б ", count: 1500)
        let client = makeClient { request in
            (200, try response(segments: [["id": 0, "text": ""]]))
        }
        await #expect(throws: TranscriptCorrection.ValidationError.self) {
            try await client.correct(source: long, glossary: glossary, apiKey: "test-key", model: "test/model")
        }
        #expect(StubProtocol.count == 1)
    }

    @Test func longUtteranceIsSplitAndRepeatedNamesKeepExactPositions() async throws {
        let text = String(repeating: "слово ", count: 1400) + "Арбита " + String(repeating: "слово ", count: 1400) + "Арбита."
        let source = "[00:00:01] A: " + text + "\n"
        let client = makeClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages.last?["content"] as? String)
            let input = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
            let segments = try #require(input["segments"] as? [[String: Any]])
            let edited = try segments.map { segment -> [String: Any] in
                let value = try #require(segment["text"] as? String)
                #expect(value.count <= 4000)
                #expect(value.utf8.count <= 8000)
                return ["id": try #require(segment["id"] as? Int),
                        "text": value.replacingOccurrences(of: "Арбита", with: "Орбита")]
            }
            return (200, try response(segments: edited))
        }
        let corrected = try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model")
        #expect(corrected == source.replacingOccurrences(of: "Арбита", with: "Орбита"))
        #expect(StubProtocol.count >= 3)
    }

    @Test func strictOutputRejectsOldSchemaAndAdditionalFields() async throws {
        let invalid = [
            #"{"changes":[]}"#,
            #"{"segments":[{"id":0,"text":"Открыли Арбиту.","extra":1}]}"#,
            #"{"segments":[{"id":0,"text":"Открыли Арбиту."}],"extra":1}"#,
            #"{"segments":[{"id":0.5,"text":"Открыли Арбиту."}]}"#,
            #"{"segments":[{"id":0,"text":null}]}"#,
            String(repeating: " ", count: 65_537)
        ]
        for text in invalid {
            let client = makeClient { _ in (200, try response(content: text)) }
            await #expect(throws: OpenRouterPostprocessor.Failure.self) {
                try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model")
            }
            #expect(StubProtocol.count == 1)
        }
    }

    @Test func stableGlossaryPrefixAndSessionEnableClaudeCacheOnlyForMultipleBatches() async throws {
        let requests = Events()
        let long = "[00:00:01] A: " + String(repeating: "слово ", count: 1200)
        let client = makeClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let blocks = try #require(messages[1]["content"] as? [[String: Any]])
            #expect((blocks[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
            #expect(body["max_tokens"] as? Int == 8192)
            let id = try #require(body["session_id"] as? String)
            #expect(UUID(uuidString: id) != nil)
            requests.add(id + (try #require(blocks[0]["text"] as? String)))
            return (200, try echo(request))
        }
        #expect(try await client.correct(source: long, glossary: glossary, apiKey: "test-key", model: "anthropic/test") == long)
        #expect(requests.values.count > 1)
        #expect(Set(requests.values).count == 1)

        for model in ["anthropic/test", "google/test"] {
            let single = makeClient { request in
                let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
                let messages = try #require(body["messages"] as? [[String: Any]])
                let blocks = try #require(messages[1]["content"] as? [[String: Any]])
                #expect(blocks[0]["cache_control"] == nil)
                return (200, try echo(request))
            }
            _ = try await single.correct(source: source, glossary: glossary, apiKey: "test-key", model: model)
        }
    }

    @Test func manyShortSegmentsAreBoundedWithoutDroppingAny() async throws {
        let source = (0..<100).map { "[00:00:01] A: слово \($0)" }.joined(separator: "\n")
        let client = makeClient { request in
            let segments = try inputSegments(request)
            #expect(segments.count <= 32)
            return (200, try echo(request))
        }
        #expect(try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model") == source)
        #expect(StubProtocol.count == 4)
    }

    @Test func oversizedLaterTokenFailsBeforeAnyPaidRequest() async throws {
        let source = "[00:00:01] A: обычная реплика\n[00:00:02] B: " + String(repeating: "а", count: 4001)
        let client = makeClient { _ in Issue.record("Unexpected request"); return (500, Data()) }
        let events = Events()
        await #expect(throws: OpenRouterPostprocessor.Failure.self) {
            try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model",
                                     onRequestStart: { events.add("pending") })
        }
        #expect(StubProtocol.count == 0)
        #expect(events.values.isEmpty)
    }

    private func makeClient(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> OpenRouterPostprocessor {
        StubProtocol.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return OpenRouterPostprocessor(session: URLSession(configuration: configuration))
    }
}

private actor Permission {
    private var enabled = true
    func allowed() -> Bool { enabled }
    func disable() { enabled = false }
}

private actor Costs {
    var values: [Double?] = []
    func add(_ cost: Double?) { values.append(cost) }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func add(_ value: String) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
}

private struct StartFailure: Error {}

private func response(segments: [[String: Any]], finish: String = "stop", cost: Any? = nil) throws -> Data {
    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["segments": segments]), as: UTF8.self)
    var body: [String: Any] = ["choices": [["finish_reason": finish, "message": ["content": content]]]]
    if let cost { body["usage"] = ["cost": cost] }
    return try JSONSerialization.data(withJSONObject: body)
}
private func response(content: String, finish: String = "stop", cost: Any? = nil) throws -> Data {
    var body: [String: Any] = ["choices": [["finish_reason": finish, "message": ["content": content]]]]
    if let cost { body["usage"] = ["cost": cost] }
    return try JSONSerialization.data(withJSONObject: body)
}
private func inputSegments(_ request: URLRequest) throws -> [[String: Any]] {
    let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let text = try #require(messages.last?["content"] as? String)
    let input = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    return try #require(input["segments"] as? [[String: Any]])
}
private func echo(_ request: URLRequest, cost: Any? = nil) throws -> Data {
    let segments = try inputSegments(request).map { ["id": $0["id"]!, "text": $0["text"]!] }
    return try response(segments: segments, cost: cost)
}
private func requestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func configure(_ value: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handler = value; requests = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let (status, data) = try handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

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
            let messages = try #require(body["messages"] as? [[String: String]])
            let input = try #require(messages.last?["content"])
            #expect(!input.contains("Закрытый заголовок"))
            #expect(!input.contains("Иван"))
            #expect(!input.contains("00:00:01"))
            #expect(!input.contains("screens/test.jpg"))
            #expect(input.contains("вымышленный продукт"))
            return (200, try response(changes: [["id": 3, "original": "Арбиту", "replacement": "Орбиту", "termIndex": 0]]))
        }
        let result = try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model")
        #expect(result == source.replacingOccurrences(of: "Арбиту", with: "Орбиту"))
        #expect(StubProtocol.count == 1)
    }

    @Test func emptySpeechDoesNotSendAnything() async throws {
        let client = makeClient { _ in Issue.record("Unexpected request"); return (500, Data()) }
        let empty = "# Встреча\n[00:00:02] (экран): screens/test.jpg\n"
        #expect(try await client.correct(source: empty, glossary: glossary, apiKey: "test-key", model: "test/model") == empty)
        #expect(StubProtocol.count == 0)
    }

    @Test func rejectsTruncatedAndMalformedResponses() async throws {
        let invalid = [
            try response(changes: [], finish: "length"),
            Data("{\"choices\":[]}".utf8),
            Data("{\"error\":{\"message\":\"private provider response\"}}".utf8),
            Data("not json".utf8),
            try response(content: "not json"),
            try response(changes: [["id": 99, "original": "Арбиту", "replacement": "Орбиту", "termIndex": 0]])
        ]
        for payload in invalid {
            let client = makeClient { _ in (200, payload) }
            await #expect(throws: OpenRouterPostprocessor.Failure.self) {
                try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model")
            }
            #expect(StubProtocol.count == 1)
        }
    }

    @Test func failureInLaterBatchDoesNotReturnPartialResultOrRetry() async throws {
        let long = "[00:00:01] A: " + String(repeating: "а", count: 7900) + "\n[00:00:02] B: " + String(repeating: "б", count: 7900)
        let client = makeClient { _ in
            StubProtocol.count == 1 ? (200, try response(changes: [])) : (429, Data("private provider response".utf8))
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

    @Test func disablingAutomaticProcessingStopsBeforeNextBatch() async throws {
        let permission = Permission()
        let long = "[00:00:01] A: " + String(repeating: "а", count: 7900) + "\n[00:00:02] B: " + String(repeating: "б", count: 7900)
        let client = makeClient { _ in (200, try response(changes: [])) }
        await #expect(throws: CancellationError.self) {
            try await client.correct(source: long, glossary: glossary, apiKey: "test-key", model: "test/model",
                                     maySend: { await permission.allowed() })
        }
        #expect(StubProtocol.count == 1)
    }

    @Test func disabledProcessingSendsNothing() async throws {
        let client = makeClient { _ in Issue.record("Unexpected request"); return (500, Data()) }
        await #expect(throws: CancellationError.self) {
            try await client.correct(source: source, glossary: glossary, apiKey: "test-key", model: "test/model", maySend: { false })
        }
        #expect(StubProtocol.count == 0)
    }

    private func makeClient(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> OpenRouterPostprocessor {
        StubProtocol.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return OpenRouterPostprocessor(session: URLSession(configuration: configuration))
    }
}

private actor Permission {
    private var calls = 0
    func allowed() -> Bool { calls += 1; return calls == 1 }
}

private func response(changes: [[String: Any]], finish: String = "stop") throws -> Data {
    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["changes": changes]), as: UTF8.self)
    return try response(content: content, finish: finish)
}
private func response(content: String, finish: String = "stop") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": ["content": content]]]])
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

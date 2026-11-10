import Foundation
import Testing
@testable import AviaCallsCore

struct OpenRouterTranscriberTests {
    @Test func sendsAudioWithWordTimestampsAndPrivacyConstraints() async throws {
        let audio = Data([0, 1, 2, 255])
        let client = OpenRouterTranscriber(transport: { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let input = try #require(body["input_audio"] as? [String: String])
            #expect(input == ["data": audio.base64EncodedString(), "format": "wav"])
            #expect(body["model"] as? String == "test/model")
            #expect(body["language"] as? String == "ru")
            #expect(body["response_format"] as? String == "verbose_json")
            #expect(body["timestamp_granularities"] as? [String] == ["word", "segment"])
            let provider = try #require(body["provider"] as? [String: Any])
            #expect(provider["zdr"] as? Bool == true)
            #expect(provider["data_collection"] as? String == "deny")
            #expect(body["messages"] == nil)
            return response(request, json: #"{"text":"Первая вторая","words":[{"word":"вторая","start":1,"end":2,"confidence":0.1},{"word":" Первая ","start":0,"end":1}],"usage":{"cost":0.025}}"#)
        })
        let result = try await client.transcribe(audio: audio, format: " WAV ", key: "test-key", model: "test/model", language: "ru", duration: 2)
        #expect(result.words == [Word(start: 0, end: 1, text: "Первая"), Word(start: 1, end: 2, text: "вторая")])
        #expect(result.cost == 0.025)
    }

    @Test func permitsSilentResponseAndOmitsUnspecifiedLanguage() async throws {
        for payload in [#"{"text":""}"#, #"{"text":"  ","words":[],"segments":[],"usage":{"cost":0}}"#] {
            let client = OpenRouterTranscriber(transport: { request in
                let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                #expect(body["language"] == nil)
                return response(request, json: payload)
            })
            #expect(try await transcribe(client).words.isEmpty)
        }
    }

    @Test func rejectsTextOrSegmentsWithoutWordTimestampsAndPreservesKnownCost() async throws {
        for payload in [
            #"{"text":"Нужно сохранить речь.","usage":{"cost":0.25}}"#,
            #"{"text":"Нужно сохранить речь.","words":[],"usage":{"cost":0.25}}"#,
            #"{"segments":[{"start":0,"end":1,"text":"Нужно сохранить речь."}],"usage":{"cost":0.25}}"#
        ] {
            let client = OpenRouterTranscriber(transport: { response($0, json: payload) })
            do { _ = try await transcribe(client); Issue.record("Expected missing timestamps") }
            catch let failure as OpenRouterTranscriber.Failure {
                #expect(failure.reason == .missingWordTimestamps)
                #expect(failure.cost == 0.25)
                #expect(failure.localizedDescription.contains("модель"))
            }
        }
    }

    @Test func rejectsInvalidTimestampsAndEmptyWordsWithoutReturningPartialText() async throws {
        let invalid = [
            #"{"word":"слово","start":-0.1,"end":1}"#,
            #"{"word":"слово","start":2,"end":1}"#,
            #"{"word":"слово","start":0,"end":10.1}"#,
            #"{"word":" ","start":0,"end":1}"#,
            #"{"word":"слово","start":1e999,"end":2}"#,
            #"{"word":"слово","start":"NaN","end":2}"#
        ]
        for word in invalid {
            let payload = #"{"text":"Речь","words":[{"word":"Корректно","start":0,"end":1},"# + word + #"],"usage":{"cost":0.1}}"#
            let client = OpenRouterTranscriber(transport: { response($0, json: payload) })
            do { _ = try await transcribe(client); Issue.record("Expected invalid timestamps") }
            catch let failure as OpenRouterTranscriber.Failure {
                #expect(failure.reason == .invalidWordTimestamps || failure.reason == .response)
                #expect(failure.cost == 0.1)
            }
        }
    }

    @Test func invalidOrAbsentCostDoesNotDiscardValidWords() async throws {
        for usage in ["null", "[]", #"{"cost":"wrong"}"#, #"{"cost":-1}"#, #"{"cost":true}"#] {
            let payload = #"{"text":"Привет","words":[{"word":"Привет","start":0,"end":1}],"usage":"# + usage + "}"
            let client = OpenRouterTranscriber(transport: { response($0, json: payload) })
            let result = try await transcribe(client)
            #expect(result.words.count == 1)
            #expect(result.cost == nil)
        }
    }

    @Test func malformedOrErrorResponsesDoNotLookLikeSilence() async throws {
        for payload in ["{}", "not JSON", #"{"error":{"message":"private provider text"}}"#, #"{"words":{}}"#] {
            let client = OpenRouterTranscriber(transport: { response($0, json: payload) })
            await #expect(throws: OpenRouterTranscriber.Failure.self) { try await transcribe(client) }
        }
    }

    @Test func retriesOnlyOneShortRateLimit() async throws {
        let calls = CallCounter()
        let waits = Waits()
        let client = OpenRouterTranscriber(transport: { request in
            let count = await calls.next()
            return response(request, status: count == 1 ? 429 : 200, json: #"{"text":""}"#, headers: ["Retry-After": "0.5"])
        }, sleep: { await waits.add($0) })
        _ = try await transcribe(client)
        #expect(await calls.count == 2)
        #expect(await waits.values == [0.5])

        let exhausted = CallCounter()
        let limited = OpenRouterTranscriber(transport: { request in
            _ = await exhausted.next()
            return response(request, status: 429, json: "", headers: ["Retry-After": "0"])
        }, sleep: { _ in })
        do { _ = try await transcribe(limited); Issue.record("Expected rate limit") }
        catch let failure as OpenRouterTranscriber.Failure {
            #expect(failure.reason == .http(429))
            #expect(failure.cost == 0)
        }
        #expect(await exhausted.count == 2)
    }

    @Test func doesNotShortenLongRetryAfterOrRetryHTTPFailures() async throws {
        for status in [400, 401, 402, 403, 404, 413, 422, 429, 500, 503] {
            let calls = CallCounter()
            let client = OpenRouterTranscriber(transport: { request in
                _ = await calls.next()
                return response(request, status: status, json: "private provider text", headers: ["Retry-After": "60"])
            }, sleep: { _ in Issue.record("Unexpected wait") })
            do { _ = try await transcribe(client); Issue.record("Expected HTTP failure") }
            catch let failure as OpenRouterTranscriber.Failure {
                #expect(failure.reason == .http(status))
                #expect(failure.cost == (status < 500 ? 0 : nil))
                #expect(!failure.localizedDescription.contains("private provider text"))
            }
            #expect(await calls.count == 1)
        }
    }

    @Test func doesNotRetryTimeoutAndDistinguishesRequestsNeverSent() async throws {
        for (code, cost) in [(URLError.Code.timedOut, nil as Double?), (.notConnectedToInternet, 0), (.networkConnectionLost, nil)] {
            let calls = CallCounter()
            let client = OpenRouterTranscriber(transport: { _ in
                _ = await calls.next()
                throw URLError(code)
            })
            do { _ = try await transcribe(client); Issue.record("Expected network failure") }
            catch let failure as OpenRouterTranscriber.Failure { #expect(failure.cost == cost) }
            #expect(await calls.count == 1)
        }
    }

    @Test func validatesInputBeforeSending() async throws {
        let client = OpenRouterTranscriber(transport: { request in
            Issue.record("Unexpected network request")
            return response(request, json: #"{"text":""}"#)
        })
        for duration in [0, -1, Double.infinity, Double.nan] {
            await #expect(throws: OpenRouterTranscriber.Failure.self) {
                try await client.transcribe(audio: Data([1]), format: "wav", key: "key", model: "model", duration: duration)
            }
        }
        await #expect(throws: OpenRouterTranscriber.Failure.self) {
            try await client.transcribe(audio: Data(), format: "wav", key: "key", model: "model", duration: 1)
        }
        await #expect(throws: OpenRouterTranscriber.Failure.self) {
            try await client.transcribe(audio: Data([1]), format: "wav", key: " ", model: "model", duration: 1)
        }
    }

    private func transcribe(_ client: OpenRouterTranscriber) async throws -> OpenRouterTranscriber.Result {
        try await client.transcribe(audio: Data([1]), format: "wav", key: "key", model: "model", duration: 10)
    }
}

private func response(_ request: URLRequest, status: Int = 200, json: String,
                      headers: [String: String] = [:]) -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
}
private actor CallCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}
private actor Waits {
    var values: [Double] = []
    func add(_ seconds: Double) { values.append(seconds) }
}

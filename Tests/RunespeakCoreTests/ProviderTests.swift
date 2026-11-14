import XCTest
@testable import RunespeakCore

// Uses StubURLProtocol / StubGlossary / RecordingUsage / SleepLog from TranslationTests.swift.

private func chat(_ body: String, sender: String? = "Thrall") -> ChatMessage {
    ChatMessage(channel: .guild, channelLabel: "길드", sender: sender, body: body,
                rawText: body, color: .white, firstSeen: Date(timeIntervalSince1970: 0))
}

private func object(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func json(_ value: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
}

private func answer(_ pairs: [(Int, String)], note: String = "") -> String {
    json(["translations": pairs.map { ["n": $0.0, "text": $0.1] as [String: Any] }, "note": note] as [String: Any])
}

/// A Responses API success body.
private func openAIResponse(text: String, status: String = "completed", refusal: String? = nil,
                            usage: (input: Int, cached: Int, write: Int, output: Int) = (3000, 2600, 0, 40)) -> String {
    var content: [[String: Any]] = [["type": "output_text", "text": text, "annotations": []]]
    if let refusal { content = [["type": "refusal", "refusal": refusal]] }
    var root: [String: Any] = [
        "id": "resp_test", "object": "response", "status": status, "model": "gpt-6-luna",
        "output": [
            ["type": "reasoning", "id": "rs_1", "summary": []] as [String: Any],
            ["type": "message", "id": "msg_1", "role": "assistant", "status": "completed", "content": content] as [String: Any],
        ],
        "usage": [
            "input_tokens": usage.input,
            "input_tokens_details": ["cached_tokens": usage.cached, "cache_write_tokens": usage.write],
            "output_tokens": usage.output,
            "output_tokens_details": ["reasoning_tokens": 12],
            "total_tokens": usage.input + usage.output,
        ] as [String: Any],
    ]
    if status == "incomplete" { root["incomplete_details"] = ["reason": "max_output_tokens"] }
    return json(root)
}

private func openAIError(code: String?, type: String = "invalid_request_error", message: String = "nope", param: String? = nil) -> String {
    json(["error": ["message": message, "type": type, "param": param as Any? ?? NSNull(), "code": code as Any? ?? NSNull()] as [String: Any]])
}

/// An Interactions API success body.
private func geminiResponse(text: String, status: String = "completed",
                            usage: (input: Int, cached: Int, output: Int, thought: Int) = (3000, 0, 40, 25)) -> String {
    json([
        "id": "v1_test", "object": "interaction", "model": "gemini-3.5-flash-lite", "status": status,
        "steps": [
            ["type": "thought", "signature": "abc"] as [String: Any],
            ["type": "model_output", "content": [["type": "text", "text": text]]] as [String: Any],
        ],
        "usage": [
            "total_input_tokens": usage.input, "total_cached_tokens": usage.cached,
            "total_output_tokens": usage.output, "total_thought_tokens": usage.thought,
            "total_tokens": usage.input + usage.output + usage.thought, "total_tool_use_tokens": 0,
        ] as [String: Any],
    ] as [String: Any])
}

private func geminiError(_ code: String, _ message: String = "nope") -> String {
    json(["error": ["code": code, "message": message]])
}

class ProviderTestCase: XCTestCase {
    var glossary: StubGlossary!
    var usage: RecordingUsage!
    var sleeps: SleepLog!

    override func setUp() {
        glossary = StubGlossary()
        usage = RecordingUsage()
        sleeps = SleepLog()
    }

    func makeTranslator(_ provider: AIProvider, key: String = "test-key") -> LLMTranslator {
        var tuning = LLMTranslator.Tuning()
        let log = sleeps!
        tuning.sleep = { log.add($0) }
        return LLMTranslator(backend: ProviderBackends.backend(for: provider), apiKey: key, glossary: glossary,
                             usage: usage, session: StubURLProtocol.session(), tuning: tuning)
    }

    func context(_ model: String, reader: ReaderLanguage = .korean, recent: [ChatMessage] = []) -> TranslationRequestContext {
        TranslationRequestContext(reader: reader, flavor: .classic, model: model, recent: recent)
    }

    func assertThrows(_ expected: TranslationError, file: StaticString = #filePath, line: UInt = #line,
                      _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as TranslationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func fillGlossary() {
        glossary.stubHints.names = [GlossaryPair(korean: "혈투의 전장", english: "Dire Maul")]
        glossary.stubHints.abbreviations = [GlossaryAbbreviation(abbr: "DM", english: "Dire Maul", korean: "혈투의 전장", note: "level 55-60 dungeon in Feralas; this sense when a wing or a tribute run is named")]
        glossary.stubHints.corrections = [CorrectionExample(source: "LFM DM", translation: "혈투의 전장 구함", note: nil)]
    }

    /// The shared protocol: one JSON payload with task, numbered lines and glossary hints.
    func assertPayload(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let data = object(Data(text.utf8))
        XCTAssertEqual(data["task"] as? String, "incoming", file: file, line: line)
        XCTAssertEqual(data["reader"] as? String, "Korean", file: file, line: line)
        let sent = data["lines"] as? [[String: Any]] ?? []
        XCTAssertEqual(sent.map { $0["n"] as? Int }, [1, 2], file: file, line: line)
        XCTAssertEqual(sent.first?["text"] as? String, "LF tank DM", file: file, line: line)
        XCTAssertEqual(sent.first?["sender"] as? String, "Thrall", file: file, line: line)
        let hints = data["glossary"] as? [String: Any] ?? [:]
        XCTAssertEqual((hints["names"] as? [[String: String]])?.first, ["ko": "혈투의 전장", "en": "Dire Maul"], file: file, line: line)
        XCTAssertEqual((hints["abbreviations"] as? [[String: String]])?.first,
                       ["abbr": "DM", "en": "Dire Maul", "ko": "혈투의 전장", "note": "level 55-60 dungeon in Feralas; this sense when a wing or a tribute run is named"], file: file, line: line)
        XCTAssertEqual((hints["corrections"] as? [[String: String]])?.first?["translation"], "혈투의 전장 구함", file: file, line: line)
        XCTAssertEqual((data["context"] as? [[String: Any]])?.first?["text"] as? String, "anyone?", file: file, line: line)
    }
}

// MARK: - OpenAI

final class OpenAITranslatorTests: ProviderTestCase {

    func testRequestShapeAndResponse() async throws {
        fillGlossary()
        StubURLProtocol.install { _, _ in .init(json: openAIResponse(text: answer([(1, "혈투의 전장 탱커 구함"), (2, "귓 주세요")]),
                                                                    usage: (3000, 2600, 100, 40))) }
        let lines = [chat("LF tank DM"), chat("pst", sender: "Jaina")]
        let result = try await makeTranslator(.openai, key: " sk-test-openai\n")
            .translateIncoming(lines, context: context("gpt-6-luna", recent: [chat("anyone?")]))
        XCTAssertEqual(result[lines[0].id]?.text, "혈투의 전장 탱커 구함")
        XCTAssertEqual(result[lines[1].id]?.text, "귓 주세요")

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let (request, body) = StubURLProtocol.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer sk-test-openai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertLessThanOrEqual(request.timeoutInterval, 30)

        let root = object(body)
        XCTAssertEqual(root["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(root["max_output_tokens"] as? Int, 16_000)
        XCTAssertEqual(root["store"] as? Bool, false)
        for absent in ["temperature", "top_p", "instructions", "stream", "system", "messages", "max_tokens"] {
            XCTAssertNil(root[absent], "\(absent) must not be sent")
        }
        // System prompt: first input item, a developer message carrying the only cache breakpoint.
        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["developer", "user"])
        let developer = try XCTUnwrap((input[0]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(developer["type"] as? String, "input_text")
        XCTAssertEqual(developer["text"] as? String, TranslationPrompt.system)
        XCTAssertEqual((developer["prompt_cache_breakpoint"] as? [String: Any])?["mode"] as? String, "explicit")
        XCTAssertEqual((root["prompt_cache_options"] as? [String: Any])?["mode"] as? String, "explicit")
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(bodyText.components(separatedBy: "\"prompt_cache_breakpoint\"").count - 1, 1)

        XCTAssertEqual((root["reasoning"] as? [String: Any])?["effort"] as? String, "none", "Luna can turn reasoning off")
        let format = try XCTUnwrap((root["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertFalse((format["name"] as? String ?? "").isEmpty)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["translations", "note"])

        let user = try XCTUnwrap((input[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(user["type"] as? String, "input_text")
        assertPayload(user["text"] as? String ?? "")

        // 3000 input = 300 full price + 2600 cache read + 100 cache write.
        XCTAssertEqual(usage.entries, [.init(provider: .openai, modelID: "gpt-6-luna", input: 300, output: 40, read: 2600, write: 100)])
    }

    func testStablePrefixAndModelSpecificSettings() async throws {
        StubURLProtocol.install { _, _ in .init(json: openAIResponse(text: answer([(1, "x")], note: "n"))) }
        let translator = makeTranslator(.openai)
        _ = try await translator.translateIncoming([chat("a")], context: context("gpt-6-luna"))
        _ = try await translator.translateOutgoing("탱커 구해요", to: "English", context: context("gpt-6-luna"))
        _ = try await translator.translateIncoming([chat("a")], context: context("gpt-6.1-sol"))
        _ = try await translator.retranslate(chat("a"), previous: nil, context: context("gpt-6.1-sol"))
        _ = try await translator.translateIncoming([chat("a")], context: context("gpt-4.1"))
        _ = try await translator.translateIncoming([chat("a")], context: context("gpt-5.4-mini"))

        // Everything before the user message is byte-identical, so the prompt cache can hit.
        let prefixes = StubURLProtocol.requests.prefix(2).map { entry -> String in
            let text = String(decoding: entry.body, as: UTF8.self)
            return String(text[..<text.range(of: "{\"role\":\"user\"")!.lowerBound])
        }
        XCTAssertEqual(Set(prefixes).count, 1)
        XCTAssertTrue(prefixes[0].hasPrefix("{\"model\":\"gpt-6-luna\",\"input\":[{\"role\":\"developer\""))

        let bodies = StubURLProtocol.requests.map { object($0.body) }
        func effort(_ i: Int) -> String? { (bodies[i]["reasoning"] as? [String: Any])?["effort"] as? String }
        XCTAssertEqual(effort(2), "low", "Sol's lowest effort is low")
        XCTAssertEqual(effort(3), "medium", "retranslation reasons more")
        XCTAssertNotNil(bodies[3]["prompt_cache_options"])
        XCTAssertNil(bodies[4]["reasoning"], "GPT-4.1 is not a reasoning model")
        XCTAssertNil(bodies[4]["prompt_cache_options"], "explicit breakpoints start with GPT-5.6")
        XCTAssertFalse(String(decoding: StubURLProtocol.requests[4].body, as: UTF8.self).contains("prompt_cache_breakpoint"))
        XCTAssertNotNil((bodies[4]["text"] as? [String: Any])?["format"])
        XCTAssertEqual(effort(5), "none")
        XCTAssertNil(bodies[5]["prompt_cache_options"])
    }

    func testErrorMapping() async {
        let cases: [(Int, String, TranslationError, Int)] = [
            (401, openAIError(code: "invalid_api_key", message: "Incorrect API key provided: sk-…"), .invalidAPIKey, 1),
            (401, openAIError(code: nil, type: "authentication_error", message: "Invalid Authentication"), .invalidAPIKey, 1),
            (429, openAIError(code: "insufficient_quota", type: "insufficient_quota", message: "You exceeded your current quota"), .insufficientCredit, 1),
            (429, openAIError(code: "credit_balance_exhausted", type: "insufficient_quota"), .insufficientCredit, 1),
            (429, openAIError(code: "project_spend_limit_exceeded", type: "insufficient_quota"), .insufficientCredit, 1),
            (429, openAIError(code: "rate_limit_exceeded", type: "rate_limit_error"), .rateLimited, 1),
            (503, openAIError(code: "server_is_overloaded", type: "service_unavailable_error"), .rateLimited, 3),
            (404, openAIError(code: "model_not_found", message: "The model `gpt-9` does not exist or you do not have access to it."), .modelNotFound("gpt-9"), 1),
            (403, openAIError(code: "model_not_found", message: "Project does not have access to model"), .modelNotFound("gpt-9"), 1),
            (403, openAIError(code: "unsupported_country_region_territory"), .badResponse("이 API 키로는 사용할 수 없습니다 (403)"), 1),
            (500, openAIError(code: nil, type: "server_error"), .badResponse("OpenAI 서버 오류 (500)"), 3),
            (400, openAIError(code: nil, message: "Invalid input"), .badResponse("요청 오류 (400): Invalid input"), 1),
        ]
        for (status, body, expected, requests) in cases {
            StubURLProtocol.install { _, _ in .init(status: status, json: body) }
            await assertThrows(expected) {
                _ = try await self.makeTranslator(.openai).translateIncoming([chat("x")], context: self.context("gpt-9"))
            }
            XCTAssertEqual(StubURLProtocol.requests.count, requests, "\(status) \(expected)")
        }
        XCTAssertTrue(usage.entries.isEmpty)
        XCTAssertEqual(TranslationError.modelNotFound("gpt-9").userMessage, "모델 'gpt-9'을(를) 쓸 수 없습니다. 설정에서 다른 모델을 골라 주세요")
    }

    func testRetryThenSuccess() async throws {
        let counter = SleepLog()
        StubURLProtocol.install { _, _ in
            counter.add(0)
            if counter.delays.count == 1 {
                return .init(status: 429, json: openAIError(code: "rate_limit_exceeded", type: "rate_limit_error"), headers: ["retry-after": "1"])
            }
            return .init(json: openAIResponse(text: answer([(1, "됨")])))
        }
        let line = chat("ok")
        let result = try await makeTranslator(.openai).translateIncoming([line], context: context("gpt-6-luna"))
        XCTAssertEqual(result[line.id]?.text, "됨")
        XCTAssertEqual(sleeps.delays, [1])
        XCTAssertEqual(usage.entries.count, 1)
    }

    func testRejectedFeaturesAreDroppedOneByOne() async throws {
        StubURLProtocol.install { _, body in
            let root = object(body)
            if root["prompt_cache_options"] != nil {
                return .init(status: 400, json: openAIError(code: "unknown_parameter", message: "Unknown parameter: 'prompt_cache_options'.", param: "prompt_cache_options"))
            }
            if let effort = (root["reasoning"] as? [String: Any])?["effort"] as? String {
                if effort == "none" {
                    return .init(status: 400, json: openAIError(code: "unsupported_value", message: "Unsupported value: 'none' is not supported with this model.", param: "reasoning.effort"))
                }
                return .init(status: 400, json: openAIError(code: "unsupported_parameter", message: "Unsupported parameter: 'reasoning.effort'.", param: "reasoning.effort"))
            }
            if root["text"] != nil {
                return .init(status: 400, json: openAIError(code: nil, message: "Invalid schema for response_format 'chat_translation'", param: "text.format.schema"))
            }
            return .init(json: openAIResponse(text: "```json\n" + answer([(1, "됨")]) + "\n```"))
        }
        let translator = makeTranslator(.openai)
        let line = chat("ok")
        let first = try await translator.translateIncoming([line], context: context("gpt-6-luna"))
        XCTAssertEqual(first[line.id]?.text, "됨")
        XCTAssertEqual(StubURLProtocol.requests.count, 5, "cache options, none, effort, schema, then success")
        XCTAssertEqual((object(StubURLProtocol.requests[2].body)["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        _ = try await translator.translateIncoming([line], context: context("gpt-6-luna"))
        XCTAssertEqual(StubURLProtocol.requests.count, 6, "remembered for that model")
    }

    func testRefusalTruncationAndGarbage() async throws {
        StubURLProtocol.install { _, _ in .init(json: openAIResponse(text: "", refusal: "I'm sorry, I cannot assist with that request.")) }
        await assertThrows(.refused) {
            _ = try await self.makeTranslator(.openai).translateIncoming([chat("x")], context: self.context("gpt-6-luna"))
        }
        let cut = "{\"translations\":[{\"n\":1,\"text\":\"하나\"},{\"n\":2,\"text\":\"잘"
        StubURLProtocol.install { _, _ in .init(json: openAIResponse(text: cut, status: "incomplete")) }
        let lines = [chat("one"), chat("two")]
        let partial = try await makeTranslator(.openai).translateIncoming(lines, context: context("gpt-6-luna"))
        XCTAssertEqual(partial, [lines[0].id: TranslationOutput(text: "하나")])

        StubURLProtocol.install { _, _ in .init(json: "<html>gateway</html>") }
        await assertThrows(.badResponse("응답을 읽을 수 없습니다")) {
            _ = try await self.makeTranslator(.openai).translateIncoming([chat("x")], context: self.context("gpt-6-luna"))
        }
    }

    func testRetranslateAndOutgoing() async throws {
        StubURLProtocol.install { _, _ in .init(json: openAIResponse(text: answer([(1, "\"/need tank for Dire Maul\"\n")], note: "DM은 혈투의 전장입니다."))) }
        let translator = makeTranslator(.openai)
        let output = try await translator.retranslate(chat("LF tank DM"), previous: "죽폐 탱 구함", context: context("gpt-6.1-sol"))
        XCTAssertEqual(output.note, "DM은 혈투의 전장입니다.")
        let request = StubURLProtocol.requests[0]
        XCTAssertGreaterThan(request.request.timeoutInterval, 30, "retranslation may take longer")
        let input = object(request.body)["input"] as? [[String: Any]] ?? []
        let payload = object(Data(((input.last?["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").utf8))
        XCTAssertEqual(payload["task"] as? String, "retranslate")
        XCTAssertEqual(payload["previous_translation"] as? String, "죽폐 탱 구함")

        // Outgoing: unquoted, no leading slash, one line — the same hygiene as Claude.
        let line = try await translator.translateOutgoing("혈장 탱커 구해요", to: "English", context: context("gpt-6-luna"))
        XCTAssertEqual(line, "need tank for Dire Maul")

        StubURLProtocol.install { _, _ in .init(json: openAIResponse(text: answer([(1, String(repeating: "가", count: 200))]))) }
        let long = try await translator.translateOutgoing("긴 말", to: "Korean", context: context("gpt-6-luna"))
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
    }

    func testEngineNameAndFactory() {
        let translator = TranslatorFactory.make(provider: .openai, apiKey: "k", glossary: glossary, usage: nil, session: StubURLProtocol.session())
        XCTAssertEqual((translator as? LLMTranslator)?.provider, .openai)
        XCTAssertEqual(translator.engineName(for: context("gpt-6-luna")), "GPT-6 Luna")
        XCTAssertEqual(translator.engineName(for: context("my-custom-model")), "my-custom-model")
        let gemini = TranslatorFactory.make(provider: .gemini, apiKey: "k", glossary: glossary, usage: nil)
        XCTAssertEqual(gemini.engineName(for: context("gemini-4-hydrogen")), "Gemini 4 Hydrogen")
        let claude = TranslatorFactory.make(provider: .claude, apiKey: "k", glossary: glossary, usage: nil)
        XCTAssertEqual(claude.engineName(for: context("claude-haiku-5-5")), "Haiku")
        XCTAssertEqual(claude.engineName(for: context("claude-fable-5-2")), "claude-fable-5-2")
    }

    func testMissingKeyAndEmptyModelMakeNoRequest() async {
        StubURLProtocol.install { _, _ in .init(status: 500) }
        await assertThrows(.missingAPIKey) {
            _ = try await self.makeTranslator(.openai, key: " ").translateIncoming([chat("x")], context: self.context("gpt-6-luna"))
        }
        await assertThrows(.modelNotFound("")) {
            _ = try await self.makeTranslator(.openai).translateIncoming([chat("x")], context: self.context("  "))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }
}

// MARK: - Gemini

final class GeminiTranslatorTests: ProviderTestCase {

    func testRequestShapeAndResponse() async throws {
        fillGlossary()
        StubURLProtocol.install { _, _ in .init(json: geminiResponse(text: answer([(1, "혈투의 전장 탱커 구함"), (2, "귓 주세요")]),
                                                                    usage: (5000, 4200, 40, 25))) }
        let lines = [chat("LF tank DM"), chat("pst", sender: "Jaina")]
        let result = try await makeTranslator(.gemini, key: "gemini-test-key")
            .translateIncoming(lines, context: context("gemini-3.5-flash-lite", recent: [chat("anyone?")]))
        XCTAssertEqual(result[lines[0].id]?.text, "혈투의 전장 탱커 구함")
        XCTAssertEqual(result[lines[1].id]?.text, "귓 주세요")

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let (request, body) = StubURLProtocol.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/interactions")
        XCTAssertNil(request.url?.query, "the key must never be in the URL")
        XCTAssertFalse(request.url!.absoluteString.contains("gemini-test-key"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-revision"), "2026-05-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))

        let root = object(body)
        XCTAssertEqual(root["model"] as? String, "gemini-3.5-flash-lite")
        XCTAssertEqual(root["system_instruction"] as? String, TranslationPrompt.system)
        XCTAssertEqual(root["store"] as? Bool, false)
        for absent in ["temperature", "contents", "generationConfig", "messages", "previous_interaction_id", "stream"] {
            XCTAssertNil(root[absent], "\(absent) must not be sent")
        }
        let format = try XCTUnwrap(root["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "text")
        XCTAssertEqual(format["mime_type"] as? String, "application/json")
        XCTAssertEqual(Set((format["schema"] as? [String: Any])?["required"] as? [String] ?? []), ["translations", "note"])
        let config = try XCTUnwrap(root["generation_config"] as? [String: Any])
        XCTAssertEqual(config["thinking_level"] as? String, "minimal", "Flash-Lite has a near-off level")
        XCTAssertEqual(config["max_output_tokens"] as? Int, 16_000)
        assertPayload(root["input"] as? String ?? "")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasPrefix("{\"model\":\"gemini-3.5-flash-lite\",\"system_instruction\":"),
                      "the stable prefix comes first for implicit caching")

        // 5000 input = 800 full price + 4200 cached; thought tokens are billed as output.
        XCTAssertEqual(usage.entries, [.init(provider: .gemini, modelID: "gemini-3.5-flash-lite", input: 800, output: 65, read: 4200, write: 0)])
    }

    func testThinkingLevelsPerModelAndProfile() async throws {
        StubURLProtocol.install { _, _ in .init(json: geminiResponse(text: answer([(1, "x")], note: "n"))) }
        let translator = makeTranslator(.gemini)
        _ = try await translator.translateIncoming([chat("a")], context: context("gemini-4-hydrogen"))
        _ = try await translator.retranslate(chat("a"), previous: nil, context: context("gemini-4-hydrogen"))
        _ = try await translator.translateIncoming([chat("a")], context: context("gemini-3.8-flash"))
        _ = try await translator.translateIncoming([chat("a")], context: context("gemini-3.6-flash"))
        let levels = StubURLProtocol.requests.map { (object($0.body)["generation_config"] as? [String: Any])?["thinking_level"] as? String }
        XCTAssertEqual(levels, ["low", "medium", "low", "minimal"])
    }

    func testErrorMapping() async {
        let cases: [(Int, String, TranslationError, Int)] = [
            (401, geminiError("authentication", "The API key is missing, invalid, or expired."), .invalidAPIKey, 1),
            (400, json(["error": ["code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT"] as [String: Any]]), .invalidAPIKey, 1),
            (402, geminiError("payment_required", "Your Prepay credit balance is depleted."), .insufficientCredit, 1),
            (429, geminiError("quota_exceeded", "You have exceeded your daily quota."), .insufficientCredit, 1),
            (400, geminiError("failed_precondition", "Billing is disabled for this project."), .insufficientCredit, 1),
            (429, geminiError("rate_limit_exceeded"), .rateLimited, 1),
            (503, geminiError("service_unavailable"), .rateLimited, 3),
            (404, geminiError("model_not_found", "The specified model was not found."), .modelNotFound("gemini-x"), 1),
            (403, geminiError("permission_denied"), .badResponse("이 API 키로는 사용할 수 없습니다 (403)"), 1),
            (500, geminiError("api_error"), .badResponse("Google 서버 오류 (500)"), 3),
            (400, geminiError("invalid_request", "bad input"), .badResponse("요청 오류 (400): bad input"), 1),
        ]
        for (status, body, expected, requests) in cases {
            StubURLProtocol.install { _, _ in .init(status: status, json: body) }
            await assertThrows(expected) {
                _ = try await self.makeTranslator(.gemini).translateIncoming([chat("x")], context: self.context("gemini-x"))
            }
            XCTAssertEqual(StubURLProtocol.requests.count, requests, "\(status) \(expected)")
        }
        XCTAssertTrue(usage.entries.isEmpty)
    }

    func testRejectedFeaturesBlockedAndTruncated() async throws {
        StubURLProtocol.install { _, body in
            let root = object(body)
            let level = (root["generation_config"] as? [String: Any])?["thinking_level"] as? String
            if level == "minimal" {
                return .init(status: 400, json: geminiError("invalid_request", "thinking_level 'minimal' is not supported for this model."))
            }
            if root["response_format"] != nil {
                return .init(status: 400, json: geminiError("invalid_request", "response_format.schema is not supported."))
            }
            return .init(json: geminiResponse(text: answer([(1, "됨")])))
        }
        let line = chat("ok")
        let result = try await makeTranslator(.gemini).translateIncoming([line], context: context("gemini-3.1-flash-lite"))
        XCTAssertEqual(result[line.id]?.text, "됨")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual((object(StubURLProtocol.requests[2].body)["generation_config"] as? [String: Any])?["thinking_level"] as? String, "low")

        let blocked = json(["id": "v1", "status": "failed", "steps": [], "error": ["code": "safety", "message": "blocked"]] as [String: Any])
        StubURLProtocol.install { _, _ in .init(json: blocked) }
        await assertThrows(.refused) {
            _ = try await self.makeTranslator(.gemini).translateIncoming([chat("x")], context: self.context("gemini-4-hydrogen"))
        }

        let cut = "{\"translations\":[{\"n\":1,\"text\":\"하나\"},{\"n\":2,\"text\":\"잘"
        StubURLProtocol.install { _, _ in .init(json: geminiResponse(text: cut, status: "incomplete")) }
        let lines = [chat("one"), chat("two")]
        let partial = try await makeTranslator(.gemini).translateIncoming(lines, context: context("gemini-4-hydrogen"))
        XCTAssertEqual(partial, [lines[0].id: TranslationOutput(text: "하나")])
    }
}

// MARK: - Model list and key check

final class ModelCatalogTests: XCTestCase {

    func testBuiltInCatalogue() {
        for provider in AIProvider.allCases {
            let models = ModelCatalog.builtIn(provider)
            XCTAssertGreaterThanOrEqual(models.count, 3)
            XCTAssertEqual(models.filter { $0.role == .fast }.count, 1)
            XCTAssertEqual(models.filter { $0.role == .careful }.count, 1)
            XCTAssertEqual(Set(models.map(\.id)).count, models.count)
            for model in models {
                let price = try! XCTUnwrap(model.price)
                XCTAssertGreaterThan(price.output, price.input)
                XCTAssertLessThan(price.cacheRead, price.input)
                XCTAssertGreaterThanOrEqual(price.cacheWrite, price.input)
                XCTAssertEqual(model.provider, provider)
            }
        }
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .claude, role: .fast), ModelChoice.haiku.modelID)
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .claude, role: .careful), ModelChoice.opus.modelID)
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .openai, role: .fast), "gpt-6-luna")
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .openai, role: .careful), "gpt-6.1-sol")
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .gemini, role: .fast), "gemini-3.5-flash-lite")
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .gemini, role: .careful), "gemini-4-hydrogen")
        XCTAssertEqual(ModelCatalog.builtIn(.openai)[0].title, "GPT-6 Luna (빠르고 저렴)")
    }

    func testPricesAndSnapshotMatching() {
        XCTAssertEqual(ModelCatalog.usd(provider: .openai, modelID: "gpt-6-luna", inputTokens: 1_000_000, outputTokens: 1_000_000,
                                        cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)!, 0.10 + 0.50 + 0.01 + 0.125, accuracy: 1e-9)
        XCTAssertEqual(ModelCatalog.usd(provider: .gemini, modelID: "gemini-4-hydrogen", inputTokens: 1_000_000, outputTokens: 1_000_000,
                                        cacheReadTokens: 1_000_000, cacheWriteTokens: 0)!, 1.50 + 7.50 + 0.075, accuracy: 1e-9)
        // Dated snapshots take the price of their base model; different models do not.
        XCTAssertEqual(ModelCatalog.price(provider: .openai, modelID: "gpt-6-luna-2026-08-01"), ModelCatalog.price(provider: .openai, modelID: "gpt-6-luna"))
        XCTAssertEqual(ModelCatalog.price(provider: .claude, modelID: "claude-haiku-5-5-20260915")?.input, 0.10)
        XCTAssertEqual(ModelCatalog.price(provider: .gemini, modelID: "gemini-3.5-flash-lite-001")?.input, 0.30)
        XCTAssertNil(ModelCatalog.price(provider: .openai, modelID: "gpt-6-luna-pro"))
        XCTAssertNil(ModelCatalog.price(provider: .openai, modelID: "gpt-5.4"))
        XCTAssertNil(ModelCatalog.price(provider: .gemini, modelID: "gpt-6-luna"), "prices are per provider")
        XCTAssertNil(ModelCatalog.usd(provider: .claude, modelID: "claude-fable-5-2", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0))
    }

    func testAnnouncedPriceChangesApplyFromTheirDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
        }
        func price(_ id: String, _ date: Date) -> ModelPrice? { ModelCatalog.price(provider: .gemini, modelID: id, at: date) }

        XCTAssertEqual(price("gemini-4-carbon", day(2026, 11, 30, hour: 23)),
                       ModelPrice(input: 2.00, output: 10.00, cacheRead: 0.10, cacheWrite: 2.00))
        XCTAssertEqual(price("gemini-4-carbon", day(2026, 12, 1)),
                       ModelPrice(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 4.00))
        XCTAssertEqual(price("gemini-3.8-flash", day(2026, 12, 31, hour: 23))?.input, 0.75)
        XCTAssertEqual(price("gemini-3.8-flash", day(2027, 1, 1)),
                       ModelPrice(input: 1.50, output: 7.50, cacheRead: 0.15, cacheWrite: 1.50))
        XCTAssertEqual(price("gemini-3.8-flash-001", day(2027, 2, 1))?.output, 7.50, "snapshots follow their base model")
        XCTAssertEqual(price("gemini-4-hydrogen", day(2027, 6, 1))?.input, 1.50, "models without an announced change keep their price")
        XCTAssertEqual(ModelCatalog.builtIn(.gemini, at: day(2026, 12, 2)).first { $0.id == "gemini-4-carbon" }?.price?.output, 20.00,
                       "the settings hint reads the same table")

        // The estimate is made with the price of the day the response is recorded.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("runespeak-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        for (date, usd) in [(day(2026, 11, 20), 2.00), (day(2026, 12, 20), 4.00)] {
            try? FileManager.default.removeItem(at: file)
            let tracker = UsageTracker(file: file, now: { date }, calendar: calendar)
            tracker.record(provider: .gemini, modelID: "gemini-4-carbon", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
            XCTAssertEqual(tracker.todayKRW, usd * ModelCatalog.krwPerUSD, accuracy: 1e-6)
        }
    }

    func testOpenAIModelListIsFilteredToChatModels() async throws {
        let ids = ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-terra", "gpt-6-luna-2026-08-01", "o3", "chat-latest",
                   "gpt-image-2.6-flare", "gpt-audio-1.5", "gpt-realtime-2.1", "gpt-live-1", "gpt-transcribe", "text-embedding-3-large",
                   "omni-moderation-latest", "gpt-oss-120b", "gpt-6-cyber", "gpt-rosalind-research", "whisper-1", "tts-1", "dall-e-3",
                   "gpt-4o-mini-tts", "gpt-4o-search-preview", "ft:gpt-6-luna:org::abc"]
        let body = json(["object": "list", "data": ids.map { ["id": $0, "object": "model", "created": 1, "owned_by": "openai"] as [String: Any] }] as [String: Any])
        StubURLProtocol.install { _, _ in .init(json: body) }
        let models = try await ModelCatalog.listModels(provider: .openai, apiKey: "sk-test\n", session: StubURLProtocol.session())

        XCTAssertEqual(models.map(\.id), ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra", "o3", "gpt-6-luna-2026-08-01", "gpt-5.6-terra", "chat-latest"],
                       "built-in models first in catalogue order, then the rest, newest-looking first")
        XCTAssertEqual(models[0].role, .fast)
        XCTAssertEqual(models[1].role, .careful)
        XCTAssertNotNil(models[0].price)
        XCTAssertEqual(models[4].price, models[0].price, "a snapshot is priced like its base model")
        XCTAssertNil(models[5].price)

        let request = StubURLProtocol.requests[0].request
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer sk-test")
    }

    func testGeminiModelListPaginatesFiltersAndKeepsKeyOutOfTheURL() async throws {
        func model(_ id: String, _ name: String, _ methods: [String] = ["generateContent", "countTokens"]) -> [String: Any] {
            ["name": "models/" + id, "displayName": name, "supportedGenerationMethods": methods]
        }
        let first = json(["models": [
            model("gemini-4-hydrogen", "Gemini 4 Hydrogen"), model("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite"),
            model("gemini-3.8-flash-tts", "TTS"), model("gemini-embedding-2", "Embedding", ["embedContent"]),
            model("gemini-3.1-flash-image", "Nano Banana 2"), model("gemini-3.8-live", "Live", ["bidiGenerateContent"]),
        ], "nextPageToken": "page two"] as [String: Any])
        let second = json(["models": [
            model("gemini-3.6-flash", "Gemini 3.6 Flash"), model("gemini-vector-1", "Vectors", ["embedContent", "countTokens"]),
            model("veo-3.1-generate-preview", "Veo"), model("gemma-4-27b-it", "Gemma"), model("gemini-omni-1.2-flash", "Omni"),
            model("gemini-3.5-transcribe", "Transcribe"), model("gemini-robotics-er-2-preview", "Robotics"),
        ]] as [String: Any])
        StubURLProtocol.install { request, _ in
            .init(json: request.url!.query!.contains("pageToken") ? second : first)
        }
        let models = try await ModelCatalog.listModels(provider: .gemini, apiKey: "gem-key", session: StubURLProtocol.session())
        XCTAssertEqual(models.map(\.id), ["gemini-3.5-flash-lite", "gemini-4-hydrogen", "gemini-3.6-flash"])
        XCTAssertEqual(models[2].displayName, "Gemini 3.6 Flash")
        XCTAssertNil(models[2].price)

        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        for (request, _) in StubURLProtocol.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gem-key")
            XCTAssertFalse(request.url!.absoluteString.contains("gem-key"), "the key must never be in the URL")
            XCTAssertTrue(request.url!.absoluteString.hasPrefix("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"))
        }
        XCTAssertEqual(URLComponents(url: StubURLProtocol.requests[1].request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pageToken" }?.value, "page two")
    }

    func testClaudeModelListPaginates() async throws {
        let first = json(["data": [["type": "model", "id": "claude-opus-5-5", "display_name": "Claude Opus 5.5"],
                                   ["type": "model", "id": "claude-fable-5-2", "display_name": "Claude Fable 5.2"]],
                          "has_more": true, "first_id": "claude-opus-5-5", "last_id": "claude-fable-5-2"] as [String: Any])
        let second = json(["data": [["type": "model", "id": "claude-haiku-5-5", "display_name": "Claude Haiku 5.5"],
                                    ["type": "model", "id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5"]],
                           "has_more": false, "last_id": "claude-haiku-4-5-20251001"] as [String: Any])
        StubURLProtocol.install { request, _ in .init(json: request.url!.query!.contains("after_id=claude-fable-5-2") ? second : first) }
        let models = try await ModelCatalog.listModels(provider: .claude, apiKey: "sk-ant-test", session: StubURLProtocol.session())
        XCTAssertEqual(models.map(\.id), ["claude-haiku-5-5", "claude-opus-5-5", "claude-haiku-4-5-20251001", "claude-fable-5-2"])
        XCTAssertEqual(models[3].displayName, "Claude Fable 5.2")
        let request = StubURLProtocol.requests[0].request
        XCTAssertTrue(request.url!.absoluteString.hasPrefix("https://api.anthropic.com/v1/models?limit=1000"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
    }

    func testValidateKey() async {
        let session = StubURLProtocol.session()
        StubURLProtocol.install { _, _ in .init(json: json(["object": "list", "data": [["id": "gpt-6-luna"]]] as [String: Any])) }
        guard case .success = await ModelCatalog.validateKey(provider: .openai, apiKey: "sk-ok", session: session) else { return XCTFail("expected success") }

        func failure(_ provider: AIProvider, key: String = "k") async -> TranslationError? {
            if case .failure(let error) = await ModelCatalog.validateKey(provider: provider, apiKey: key, session: session) { return error }
            return nil
        }
        StubURLProtocol.install { _, _ in .init(status: 401, json: openAIError(code: "invalid_api_key")) }
        let openAI = await failure(.openai)
        XCTAssertEqual(openAI, .invalidAPIKey)
        StubURLProtocol.install { _, _ in .init(status: 401, json: json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]] as [String: Any])) }
        let claude = await failure(.claude)
        XCTAssertEqual(claude, .invalidAPIKey)
        // The Gemini model list reports a bad key as 400 INVALID_ARGUMENT in the older error format.
        StubURLProtocol.install { _, _ in
            .init(status: 400, json: json(["error": ["code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT",
                                                     "details": [["reason": "API_KEY_INVALID"]]] as [String: Any]]))
        }
        let gemini = await failure(.gemini)
        XCTAssertEqual(gemini, .invalidAPIKey)
        StubURLProtocol.install { _, _ in .init(error: .notConnectedToInternet) }
        let offline = await failure(.gemini)
        XCTAssertEqual(offline, .network("인터넷에 연결되어 있지 않습니다"))
        StubURLProtocol.install { _, _ in .init(status: 404, json: "{}") }
        let missing = await failure(.openai)
        XCTAssertEqual(missing, .badResponse("요청한 주소를 찾을 수 없습니다 (404)"))

        StubURLProtocol.install { _, _ in .init(status: 500) }
        let empty = await failure(.claude, key: "  ")
        XCTAssertEqual(empty, .missingAPIKey)
        XCTAssertEqual(StubURLProtocol.requests.count, 0, "an empty key makes no request")
    }
}

// MARK: - Settings, paths, messages

final class ProviderSettingsTests: XCTestCase {

    func testProviderMetadata() {
        XCTAssertEqual(AIProvider.allCases.map(\.rawValue), ["claude", "openai", "gemini"])
        XCTAssertEqual(AIProvider.allCases.map(\.title), ["Claude (Anthropic)", "ChatGPT (OpenAI)", "Gemini (Google)"])
        for provider in AIProvider.allCases {
            XCTAssertEqual(provider.keyConsoleURL.scheme, "https")
            XCTAssertFalse(provider.keyFormatHint.isEmpty)
        }
        XCTAssertTrue(AIProvider.claude.looksLikeKey("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(AIProvider.openai.looksLikeKey("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"), "a Claude key pasted in the ChatGPT box")
        XCTAssertTrue(AIProvider.openai.looksLikeKey("sk-proj-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(AIProvider.gemini.looksLikeKey("sk-proj-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(AIProvider.gemini.looksLikeKey("AIzaSyA-abcdefghijklmnopqrstuvwxyz012345"))
        XCTAssertFalse(AIProvider.gemini.looksLikeKey("short"))
    }

    func testDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.provider, .claude)
        XCTAssertEqual(settings.modelID(), "claude-haiku-5-5")
        XCTAssertEqual(settings.retranslateModelID(), "claude-opus-5-5")
        XCTAssertEqual(settings.modelID(for: .openai), "gpt-6-luna")
        XCTAssertEqual(settings.retranslateModelID(for: .gemini), "gemini-4-hydrogen")
        XCTAssertEqual(settings.model, .haiku)
        XCTAssertEqual(settings.retranslateModel, .opus)
    }

    func testRoundTripPerProviderModelsAndTolerantDecoding() throws {
        var settings = AppSettings()
        settings.provider = .gemini
        settings.setModelID(" gemini-3.8-flash ", for: .gemini)
        settings.setRetranslateModelID("gemini-4-carbon", for: .gemini)
        settings.setModelID("my-fine-tune", for: .openai)
        XCTAssertEqual(settings.modelID(), "gemini-3.8-flash")
        XCTAssertEqual(settings.retranslateModelID(), "gemini-4-carbon")
        XCTAssertEqual(settings.modelID(for: .openai), "my-fine-tune", "any custom id is kept")
        XCTAssertEqual(settings.modelID(for: .claude), "claude-haiku-5-5")
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(reloaded, settings)

        settings.setModelID("  ", for: .gemini)
        XCTAssertEqual(settings.modelID(), "gemini-3.5-flash-lite", "clearing goes back to the default")
        settings.model = .opus
        XCTAssertEqual(settings.modelID(for: .claude), "claude-opus-5-5")
        XCTAssertEqual(settings.modelID(), "gemini-3.5-flash-lite", "the Claude shorthand does not touch other providers")

        // Unknown keys are ignored; unknown or damaged values fall back instead of failing.
        let mixed = #"{"provider":"openai","model":"haiku","translationModels":{"claude":"claude-opus-5-5","openai":""},"retranslationModels":"oops"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(mixed.utf8))
        XCTAssertEqual(decoded.provider, .openai)
        XCTAssertEqual(decoded.modelID(for: .claude), "claude-opus-5-5")
        XCTAssertEqual(decoded.modelID(), "gpt-6-luna")
        XCTAssertEqual(decoded.retranslateModelID(), "gpt-6.1-sol")
        let future = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"provider":"some-new-ai","model":"ultra","fontSize":18}"#.utf8))
        XCTAssertEqual(future.provider, .claude)
        XCTAssertEqual(future.modelID(), "claude-haiku-5-5")
        XCTAssertEqual(future.fontSize, 18)
    }

    func testKeyFilesPerProvider() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/runespeak-test"))
        XCTAssertEqual(paths.keyFile(for: .claude).lastPathComponent, "key_claude.txt")
        XCTAssertEqual(paths.keyFile(for: .openai).lastPathComponent, "key_openai.txt")
        XCTAssertEqual(paths.keyFile(for: .gemini).lastPathComponent, "key_gemini.txt")
        XCTAssertEqual(paths.keyFile, paths.keyFile(for: .claude), "the shorthand is the Claude key file")
    }

    func testErrorMessagesDoNotNameAProviderUnlessAsked() {
        let all: [TranslationError] = [.missingAPIKey, .invalidAPIKey, .insufficientCredit, .rateLimited, .dailyLimitReached,
                                       .modelNotFound("gpt-9"), .network("x"), .badResponse("y")]
        for error in all {
            for word in ["Claude", "Anthropic", "ChatGPT", "OpenAI", "Gemini", "Google"] {
                XCTAssertFalse(error.userMessage.contains(word), "\(error) names \(word)")
            }
            XCTAssertFalse(error.userMessage.isEmpty)
        }
        XCTAssertEqual(TranslationError.missingAPIKey.userMessage, "API 키가 없습니다")
        XCTAssertEqual(TranslationError.invalidAPIKey.userMessage(for: .openai), "ChatGPT API 키가 올바르지 않습니다")
        XCTAssertEqual(TranslationError.missingAPIKey.userMessage(for: .gemini), "Gemini API 키가 없습니다")
        XCTAssertEqual(TranslationError.insufficientCredit.userMessage(for: .claude), "Anthropic 계정의 잔액 또는 사용 한도가 부족합니다")
        XCTAssertEqual(TranslationError.rateLimited.userMessage(for: .gemini), TranslationError.rateLimited.userMessage)
    }
}

// MARK: - Usage across providers

final class ProviderUsageTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("token_usage.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("runespeak-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testRecordsPerProviderAndFlagsUnknownPrices() throws {
        let tracker = UsageTracker(file: file)
        XCTAssertFalse(tracker.todayHasUnknownCost)
        tracker.record(provider: .openai, modelID: "gpt-6-luna", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        tracker.record(provider: .gemini, modelID: "gemini-4-hydrogen", inputTokens: 0, outputTokens: 1_000_000, cacheReadTokens: 0, cacheWriteTokens: 0)
        XCTAssertEqual(tracker.todayKRW, (0.10 + 7.50) * ModelCatalog.krwPerUSD, accuracy: 1e-6)
        XCTAssertFalse(tracker.todayHasUnknownCost)
        XCTAssertFalse(tracker.totalHasUnknownCost)

        // A model without a price: tokens are counted, the cost is not, and the tracker says so.
        tracker.record(provider: .openai, modelID: "my-fine-tune", inputTokens: 500, outputTokens: 70, cacheReadTokens: 0, cacheWriteTokens: 0)
        XCTAssertEqual(tracker.todayKRW, (0.10 + 7.50) * ModelCatalog.krwPerUSD, accuracy: 1e-6)
        XCTAssertTrue(tracker.todayHasUnknownCost)
        XCTAssertTrue(tracker.totalHasUnknownCost)

        let reloaded = UsageTracker(file: file)
        XCTAssertTrue(reloaded.totalHasUnknownCost)
        XCTAssertEqual(reloaded.totalKRW, tracker.totalKRW, accuracy: 1e-9)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let day = try XCTUnwrap((root["days"] as? [String: [String: Any]])?.values.first)
        XCTAssertEqual(day["unpricedRequests"] as? Int, 1)
        let models = try XCTUnwrap(day["models"] as? [String: [String: Int]])
        XCTAssertEqual(Set(models.keys), ["openai:gpt-6-luna", "gemini:gemini-4-hydrogen", "openai:my-fine-tune"])
        XCTAssertEqual(models["openai:my-fine-tune"]?["inputTokens"], 500)
        XCTAssertEqual(models["openai:my-fine-tune"]?["outputTokens"], 70)
    }

    func testUsageFileWithOtherKeysAndNoUnpricedCountStillLoads() throws {
        // A hand-kept file: bare model names as keys, no unpricedRequests.
        let old = """
        {"days":{"2026-10-01":{"models":{"haiku":{"cacheReadTokens":2500,"cacheWriteTokens":0,"inputTokens":200,"outputTokens":40,"requests":1},\
        "opus":{"cacheReadTokens":0,"cacheWriteTokens":2500,"inputTokens":300,"outputTokens":500,"requests":1}},"usd":0.0237}},"version":1}
        """
        try Data(old.utf8).write(to: file)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let tracker = UsageTracker(file: file, now: { Date(timeIntervalSince1970: 1_794_500_000) }, calendar: calendar)
        XCTAssertEqual(tracker.totalKRW, 0.0237 * ModelCatalog.krwPerUSD, accuracy: 1e-6)
        XCTAssertEqual(tracker.todayKRW, 0)
        XCTAssertFalse(tracker.totalHasUnknownCost)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".broken"), "such a file must not be treated as corrupt")

        tracker.record(provider: .gemini, modelID: "gemini-3.5-flash-lite", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        XCTAssertEqual(tracker.totalKRW, (0.0237 + 0.30) * ModelCatalog.krwPerUSD, accuracy: 1e-6)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let days = try XCTUnwrap(root["days"] as? [String: [String: Any]])
        XCTAssertEqual(days.count, 2)
        XCTAssertNotNil((days["2026-10-01"]?["models"] as? [String: Any])?["haiku"], "entries under other keys are kept as they were")
    }

    func testClaudeShorthandRecordsUnderTheModelID() {
        let tracker = UsageTracker(file: file)
        (tracker as UsageTracking).record(model: .sonnet, inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        XCTAssertEqual(tracker.todayKRW, 2 * ModelCatalog.krwPerUSD, accuracy: 1e-6)
        XCTAssertFalse(tracker.todayHasUnknownCost)
    }
}

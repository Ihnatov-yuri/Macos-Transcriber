import XCTest
@testable import Transcriberr

/// What each cloud API is sent. A parameter a model does not take is an
/// HTTP 400 for every request, so each rule is pinned here.
final class CloudRequestTests: XCTestCase {
    func testClaudeGetsNoSamplingParameters() {
        let body = CloudRequests.anthropicText(
            model: CloudRequests.Models.anthropic, system: "s", user: "u", maxTokens: 32)
        for key in ["temperature", "top_p", "top_k"] {
            XCTAssertNil(body[key], "\(key) is rejected by current Claude models")
        }
        XCTAssertEqual(body["max_tokens"] as? Int, 32)
        XCTAssertEqual(body["system"] as? String, "s")
    }

    func testOpenAIChatModelTakesTemperatureAndMaxTokens() {
        let body = CloudRequests.openAIText(model: "gpt-4o", system: "s", user: "u", maxTokens: 32)
        XCTAssertEqual(body["max_tokens"] as? Int, 32)
        XCTAssertNotNil(body["temperature"])
        XCTAssertNil(body["max_completion_tokens"])
    }

    func testOpenAIReasoningModelTakesNeither() {
        for model in ["o3-mini", "o4-mini", "gpt-5", "GPT-5-mini"] {
            let body = CloudRequests.openAIText(model: model, system: "s", user: "u", maxTokens: 32)
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 32, model)
            XCTAssertNil(body["max_tokens"], model)
            XCTAssertNil(body["temperature"], model)
        }
        XCTAssertFalse(CloudRequests.isOpenAIReasoningModel("gpt-4o"))
    }

    func testGeminiThinkingBudget() {
        // 2.5 Pro cannot disable thinking; Flash can.
        XCTAssertEqual(CloudRequests.geminiThinkingBudget(for: "gemini-2.5-pro"), 128)
        XCTAssertEqual(CloudRequests.geminiThinkingBudget(for: "gemini-2.5-flash"), 0)
    }

    /// A 32-token title on 2.5 Pro: the thinking floor comes on top of the
    /// answer's budget, not out of it.
    func testGeminiTextLeavesTheAnswerItsTokens() throws {
        let body = CloudRequests.geminiText(model: "gemini-2.5-pro", system: "s", user: "u", maxTokens: 32)
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 32 + 128)
        let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingBudget"] as? Int, 128)
    }

    func testGeminiAudioHoldsThinkingToTheFloor() throws {
        let body = CloudRequests.geminiAudio(model: "gemini-2.5-flash", wavBase64: "AA==", prompt: "p")
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingBudget"] as? Int, 0)
    }

    /// Every body must survive JSONSerialization, which the backends use.
    func testBodiesSerialize() {
        let bodies: [[String: Any]] = [
            CloudRequests.anthropicText(model: "m", system: "s", user: "u", maxTokens: 1),
            CloudRequests.openAIText(model: "gpt-5", system: "s", user: "u", maxTokens: 1),
            CloudRequests.geminiText(model: "m", system: "s", user: "u", maxTokens: 1),
            CloudRequests.geminiAudio(model: "m", wavBase64: "AA==", prompt: "p"),
        ]
        for body in bodies { XCTAssertTrue(JSONSerialization.isValidJSONObject(body)) }
    }
}

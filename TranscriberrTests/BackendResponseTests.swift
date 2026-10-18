import XCTest
@testable import Transcriberr

/// 4.5.0: cloud text replies count only when the model finished. A reply cut
/// at the token limit used to be saved as a complete summary.
final class BackendResponseTests: XCTestCase {
    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func gemini(finish: String?, parts: [[String: Any]]) -> Data {
        var candidate: [String: Any] = ["content": ["parts": parts]]
        if let finish { candidate["finishReason"] = finish }
        return json(["candidates": [candidate]])
    }

    func testGeminiFinishedReplyDropsThoughtParts() throws {
        let data = gemini(finish: "STOP", parts: [
            ["text": "planning…", "thought": true],
            ["text": "Summary: "], ["text": "done."]
        ])
        XCTAssertEqual(try GoogleGeminiBackend.parseTextResponse(data, allowEmpty: false), "Summary: done.")
    }

    func testGeminiRejectsCutOffAndBlockedReplies() {
        for finish in ["MAX_TOKENS", "SAFETY", "RECITATION"] {
            let data = gemini(finish: finish, parts: [["text": "half a sum"]])
            XCTAssertThrowsError(try GoogleGeminiBackend.parseTextResponse(data, allowEmpty: true), finish)
        }
        XCTAssertThrowsError(try GoogleGeminiBackend.parseTextResponse(
            json(["promptFeedback": ["blockReason": "SAFETY"]]), allowEmpty: true))
        XCTAssertThrowsError(try GoogleGeminiBackend.parseTextResponse(Data("<html>".utf8), allowEmpty: true))
    }

    func testGeminiEmptyIsASilentChunkButNotAnOutput() throws {
        let data = gemini(finish: "STOP", parts: [])
        XCTAssertEqual(try GoogleGeminiBackend.parseTextResponse(data, allowEmpty: true), "")
        XCTAssertThrowsError(try GoogleGeminiBackend.parseTextResponse(data, allowEmpty: false))
    }

    private func openAI(finish: String?, content: String?) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content { message["content"] = content }
        var choice: [String: Any] = ["message": message]
        if let finish { choice["finish_reason"] = finish }
        return json(["choices": [choice]])
    }

    func testOpenAIFinishedReply() throws {
        XCTAssertEqual(try OpenAIBackend.parseTextResponse(openAI(finish: "stop", content: "- point")), "- point")
    }

    func testOpenAIRejectsCutOffFilteredAndEmptyReplies() {
        XCTAssertThrowsError(try OpenAIBackend.parseTextResponse(openAI(finish: "length", content: "half")))
        XCTAssertThrowsError(try OpenAIBackend.parseTextResponse(openAI(finish: "content_filter", content: "x")))
        XCTAssertThrowsError(try OpenAIBackend.parseTextResponse(openAI(finish: nil, content: "x")))
        XCTAssertThrowsError(try OpenAIBackend.parseTextResponse(openAI(finish: "stop", content: "  ")))
        XCTAssertThrowsError(try OpenAIBackend.parseTextResponse(json(["error": ["message": "x"]])))
    }
}

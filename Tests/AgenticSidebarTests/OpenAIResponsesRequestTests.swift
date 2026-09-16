import Foundation
import XCTest
@testable import AgenticSidebar

final class OpenAIResponsesRequestTests: XCTestCase {
    func testRequestEncodesConversationStreamingAndReasoningEffort() throws {
        let request = ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-5.6"),
                variantID: ProviderVariantID("high")
            ),
            messages: [
                ChatMessage(role: .user, text: "Hello"),
                ChatMessage(role: .assistant, text: "Hi there")
            ],
            speedMode: .normal
        )

        let urlRequest = try OpenAIResponsesRequest.make(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test-token",
            providerRequest: request
        )

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://example.test/v1/responses")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(urlRequest.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "gpt-5.6")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertNil(
            object["instructions"],
            "Normal mode must leave the provider's own instructions in place"
        )

        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")

        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[0]["content"] as? String, "Hello")
        XCTAssertEqual(input[1]["role"] as? String, "assistant")
        XCTAssertEqual(input[1]["content"] as? String, "Hi there")

        XCTAssertFalse(
            String(decoding: body, as: UTF8.self).contains("test-token"),
            "Authorization material must not be encoded into the JSON body"
        )
    }

    func testRequestOmitsReasoningWhenNoVariantIsSelected() throws {
        let request = ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-6-astra"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "Hello")],
            speedMode: .normal
        )

        let urlRequest = try OpenAIResponsesRequest.make(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test-token",
            providerRequest: request
        )
        let body = try XCTUnwrap(urlRequest.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertNil(object["reasoning"])
    }

    func testFastModeCarriesTheSpeedInstructionAsSystemInstructions() throws {
        let request = ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-6-astra"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "Hello")],
            speedMode: .fast
        )

        let urlRequest = try OpenAIResponsesRequest.make(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test-token",
            providerRequest: request
        )
        let body = try XCTUnwrap(urlRequest.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(
            object["instructions"] as? String,
            ResponseSpeedMode.fast.instruction
        )
    }
}

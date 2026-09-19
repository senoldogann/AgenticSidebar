import Foundation
import XCTest

@testable import AgenticSidebar

/// Akıl yürütme rozeti sözleşmesi: açık sözcükler, bütün-jeton kodlar ve
/// aile önekleri; çıplak alt-dize yanlış tutmamalı (`command-r`,
/// `claude-3-5-sonnet` rozetsiz kalır).
final class ProviderThinkingTests: XCTestCase {
    private func capability(
        id: String,
        displayName: String? = nil,
        variants: [String] = []
    ) -> ProviderModelCapability {
        ProviderModelCapability(
            id: ProviderModelID(id),
            displayName: displayName ?? id,
            variants: variants.map {
                ProviderVariant(id: ProviderVariantID($0), displayName: $0)
            }
        )
    }

    func testExplicitWordsWin() {
        XCTAssertTrue(capability(id: "acme/super-reasoning-v2").supportsThinking)
        XCTAssertTrue(capability(id: "plain", displayName: "Plain Thinking Mode").supportsThinking)
        XCTAssertTrue(capability(id: "plain", variants: ["low", "XHigh Thinking"]).supportsThinking)
    }

    func testShortCodesNeedWholeTokens() {
        XCTAssertTrue(capability(id: "deepseek/deepseek-r1").supportsThinking)
        XCTAssertTrue(capability(id: "openai/o1").supportsThinking)
        XCTAssertTrue(capability(id: "openai/o1-mini").supportsThinking)
        XCTAssertTrue(capability(id: "openai/o3").supportsThinking)
        XCTAssertTrue(capability(id: "openai/o4-mini").supportsThinking)
        XCTAssertTrue(capability(id: "qwen/qwq-32b").supportsThinking)

        XCTAssertFalse(capability(id: "cohere/command-r-plus").supportsThinking)
        XCTAssertFalse(capability(id: "openai/gpt-4o-2024-05-13").supportsThinking)
        // `r1` tek başına sinyal değildir: akıl yürütmeyen `-r1` sonekli
        // adlar rozetsiz kalır, DeepSeek ailesi rozetini korur.
        XCTAssertFalse(capability(id: "cohere/command-r1").supportsThinking)
        XCTAssertFalse(capability(id: "acme/translator-r1").supportsThinking)
        XCTAssertTrue(capability(id: "deepseek/deepseek-r1-distill-qwen-32b").supportsThinking)
    }

    func testFamilies() {
        XCTAssertTrue(capability(id: "anthropic/claude-sonnet-4-5").supportsThinking)
        XCTAssertTrue(
            capability(id: "x", displayName: "Claude Sonnet 4.5").supportsThinking,
            "Ayraç biçimi fark etmemeli"
        )
        XCTAssertTrue(capability(id: "anthropic/claude-opus-4-1").supportsThinking)
        XCTAssertTrue(capability(id: "anthropic/claude-3-7-sonnet").supportsThinking)
        XCTAssertTrue(capability(id: "google/gemini-2.5-flash").supportsThinking)
        XCTAssertTrue(capability(id: "openai/gpt-5").supportsThinking)
        XCTAssertTrue(capability(id: "openai/gpt-5-mini").supportsThinking)
        XCTAssertTrue(capability(id: "qwen/qwen3-235b-a22b").supportsThinking)
        XCTAssertTrue(capability(id: "deepseek/deepseek-reasoner").supportsThinking)
    }

    func testNonThinkingFamiliesStayQuiet() {
        XCTAssertFalse(capability(id: "anthropic/claude-3-5-sonnet").supportsThinking)
        XCTAssertFalse(capability(id: "deepseek/deepseek-chat").supportsThinking)
        XCTAssertFalse(capability(id: "deepseek/deepseek-v3").supportsThinking)
        XCTAssertFalse(capability(id: "openai/gpt-4o").supportsThinking)
        XCTAssertFalse(capability(id: "meta/llama-3.3-70b-versatile").supportsThinking)
        XCTAssertFalse(capability(id: "mistral/mistral-large").supportsThinking)
    }
}

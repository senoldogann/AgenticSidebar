import Foundation
import XCTest

@testable import AgenticSidebar

final class ReasoningEffortPresentationTests: XCTestCase {
    func testFastModeRidesWithTheEffortAndOnlyWhenItIsOn() {
        XCTAssertEqual(
            ReasoningEffortPresentation.label(variantName: "XHigh", isFast: true),
            "XHigh · Fast"
        )
        XCTAssertEqual(
            ReasoningEffortPresentation.label(variantName: "XHigh", isFast: false),
            "XHigh",
            "Fast mode off is the absence of a word, not a second word"
        )
        XCTAssertEqual(
            ReasoningEffortPresentation.label(variantName: "Default", isFast: false),
            "Default"
        )
    }

    func testTheDefaultRowSaysSoInWords() {
        XCTAssertEqual(
            ReasoningEffortPresentation.rowTitle("High", isDefault: true),
            "High · Default"
        )
        XCTAssertEqual(
            ReasoningEffortPresentation.rowTitle("Medium", isDefault: false),
            "Medium"
        )
    }

    func testTheSummaryStatesBothSettings() {
        XCTAssertEqual(
            ReasoningEffortPresentation.summary(variantName: "High", isFast: true),
            "Reasoning effort High, fast mode on"
        )
        XCTAssertEqual(
            ReasoningEffortPresentation.summary(variantName: "High", isFast: false),
            "Reasoning effort High, fast mode off"
        )
    }
}

final class ProviderLogoTests: XCTestCase {
    func testKnownProvidersAreRecognisedFromTheirIdentifiers() {
        XCTAssertEqual(ProviderLogo.matching("opencode"), .openCode)
        XCTAssertEqual(ProviderLogo.matching("openai"), .openAI)
        XCTAssertEqual(ProviderLogo.matching("openai/gpt-5-codex"), .openAI)
        XCTAssertEqual(ProviderLogo.matching("anthropic/claude-sonnet-4"), .anthropic)
        XCTAssertEqual(ProviderLogo.matching("google/gemini-2.5-pro"), .google)
        XCTAssertEqual(ProviderLogo.matching("xai/grok-4"), .xAI)
    }

    /// The identifier is often `provider/model`, so the model name has to be able
    /// to identify the provider on its own.
    func testAModelNameIdentifiesItsProvider() {
        XCTAssertEqual(ProviderLogo.matching("gpt-5"), .openAI)
        XCTAssertEqual(ProviderLogo.matching("claude-opus-4-1"), .anthropic)
        XCTAssertEqual(ProviderLogo.matching("gemini-2.5-flash"), .google)
        XCTAssertEqual(ProviderLogo.matching("grok-3"), .xAI)
    }

    func testAnUnknownProviderGetsAnHonestInitialRatherThanNothing() {
        XCTAssertEqual(ProviderLogo.matching("mistral/mistral-large"), .generic("MI"))
        XCTAssertEqual(ProviderLogo.matching(""), .generic("?"))
        XCTAssertEqual(ProviderLogo.matching("deepseek-v3"), .generic("DE"))
    }

    func testEveryLogoHasAnAccessibleName() {
        for logo in [
            ProviderLogo.openAI,
            .anthropic,
            .google,
            .openCode,
            .xAI,
            .generic("MI"),
        ] {
            XCTAssertFalse(logo.accessibilityName.isEmpty)
        }
    }
}

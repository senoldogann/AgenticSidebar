import XCTest

@testable import AgenticSidebar

final class ProviderCapabilitiesTests: XCTestCase {
    func testModelLookupUsesExactIdentifier() {
        let capabilities = makeCapabilities()

        XCTAssertEqual(
            capabilities.model(id: ProviderModelID("alpha"))?.displayName,
            "Alpha"
        )
        XCTAssertNil(capabilities.model(id: ProviderModelID("missing")))
    }

    /// Biçime dayanıklı yedek: aynı model değişik yazımla da eşleşir, payda
    /// bulunamazsa halka bilinmeyene düşmez.
    func testModelLookupFallsBackToNormalizedIdentifier() {
        let capabilities = ProviderCapabilities(
            id: ProviderID("test"),
            displayName: "Test Provider",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("openai/gpt-5"),
                    displayName: "GPT-5",
                    variants: [],
                    contextLimit: 400_000
                )
            ]
        )

        XCTAssertEqual(
            capabilities.model(id: ProviderModelID("OpenAI/GPT-5"))?.displayName,
            "GPT-5"
        )
        XCTAssertEqual(
            capabilities.model(id: ProviderModelID("openai_gpt 5"))?.contextLimit,
            400_000
        )
        XCTAssertNil(capabilities.model(id: ProviderModelID("openai/gpt-6")))
    }

    func testVariantSupportIsScopedToSelectedModel() {
        let capabilities = makeCapabilities()

        XCTAssertTrue(
            capabilities.supports(
                variantID: ProviderVariantID("fast"),
                for: ProviderModelID("alpha")
            )
        )
        XCTAssertFalse(
            capabilities.supports(
                variantID: ProviderVariantID("deep"),
                for: ProviderModelID("alpha")
            )
        )
        XCTAssertTrue(
            capabilities.supports(
                variantID: nil,
                for: ProviderModelID("plain")
            )
        )
        XCTAssertFalse(
            capabilities.supports(
                variantID: ProviderVariantID("fast"),
                for: ProviderModelID("plain")
            )
        )
    }

    private func makeCapabilities() -> ProviderCapabilities {
        ProviderCapabilities(
            id: ProviderID("test"),
            displayName: "Test Provider",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("alpha"),
                    displayName: "Alpha",
                    variants: [
                        ProviderVariant(
                            id: ProviderVariantID("fast"),
                            displayName: "Fast"
                        )
                    ]
                ),
                ProviderModelCapability(
                    id: ProviderModelID("beta"),
                    displayName: "Beta",
                    variants: [
                        ProviderVariant(
                            id: ProviderVariantID("deep"),
                            displayName: "Deep"
                        )
                    ]
                ),
                ProviderModelCapability(
                    id: ProviderModelID("plain"),
                    displayName: "Plain",
                    variants: []
                ),
            ]
        )
    }
}

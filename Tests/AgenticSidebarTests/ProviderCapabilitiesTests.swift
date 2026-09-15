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
                )
            ]
        )
    }
}

import XCTest
@testable import AgenticSidebar

final class OpenAIModelCatalogTests: XCTestCase {
    func testAstraUsesVerifiedReasoningEffortsWithoutNone() throws {
        let models = OpenAIModelCatalog.models(
            accessibleIDs: ["gpt-6-astra"]
        )
        let astra = try XCTUnwrap(models.first)

        XCTAssertEqual(astra.id, ProviderModelID("gpt-6-astra"))
        XCTAssertEqual(
            astra.variants.map(\.id),
            ["low", "medium", "high", "xhigh", "max"].map(ProviderVariantID.init)
        )
    }

    func testGPT56FamilyUsesVerifiedReasoningEffortsIncludingNone() throws {
        let models = OpenAIModelCatalog.models(
            accessibleIDs: ["gpt-5.6", "gpt-5.6-terra", "gpt-5.6-luna"]
        )
        let expected = ["none", "low", "medium", "high", "xhigh", "max"]
            .map(ProviderVariantID.init)

        XCTAssertEqual(models.count, 3)
        XCTAssertTrue(models.allSatisfy { $0.variants.map(\.id) == expected })
    }

    func testUnknownModelsAreExcluded() {
        let models = OpenAIModelCatalog.models(
            accessibleIDs: ["gpt-6-astra", "future-unverified-model"]
        )

        XCTAssertEqual(models.map(\.id), [ProviderModelID("gpt-6-astra")])
    }

    func testGPT56AliasSuppressesDuplicateSolEntry() {
        let models = OpenAIModelCatalog.models(
            accessibleIDs: ["gpt-5.6-sol", "gpt-5.6", "gpt-5.6-luna"]
        )

        XCTAssertEqual(
            models.map(\.id),
            [ProviderModelID("gpt-5.6"), ProviderModelID("gpt-5.6-luna")]
        )
    }

    func testSolIsExposedWhenAliasIsUnavailable() {
        let models = OpenAIModelCatalog.models(
            accessibleIDs: ["gpt-5.6-sol"]
        )

        XCTAssertEqual(models.map(\.id), [ProviderModelID("gpt-5.6-sol")])
    }
}

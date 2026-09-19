import Foundation

enum OpenAIModelCatalog {
    static func models(accessibleIDs: Set<String>) -> [ProviderModelCapability] {
        var models: [ProviderModelCapability] = []

        if accessibleIDs.contains("gpt-6-astra") {
            models.append(
                model(
                    id: "gpt-6-astra",
                    displayName: "GPT-6 Astra",
                    effortIDs: ["low", "medium", "high", "xhigh", "max"],
                    // Model sayfası: 1.050.000 bağlam penceresi.
                    contextLimit: 1_050_000
                )
            )
        }

        if accessibleIDs.contains("gpt-5.6") {
            models.append(
                model(
                    id: "gpt-5.6",
                    displayName: "GPT-5.6",
                    effortIDs: gpt56EffortIDs,
                    // Aile sayfası: 1.050.000 bağlam penceresi (272K yalnız
                    // fiyat katmanıdır, API penceresini kesmez).
                    contextLimit: 1_050_000
                )
            )
        } else if accessibleIDs.contains("gpt-5.6-sol") {
            models.append(
                model(
                    id: "gpt-5.6-sol",
                    displayName: "GPT-5.6 Sol",
                    effortIDs: gpt56EffortIDs,
                    contextLimit: 1_050_000
                )
            )
        }

        if accessibleIDs.contains("gpt-5.6-terra") {
            models.append(
                model(
                    id: "gpt-5.6-terra",
                    displayName: "GPT-5.6 Terra",
                    effortIDs: gpt56EffortIDs,
                    contextLimit: 1_050_000
                )
            )
        }

        if accessibleIDs.contains("gpt-5.6-luna") {
            models.append(
                model(
                    id: "gpt-5.6-luna",
                    displayName: "GPT-5.6 Luna",
                    effortIDs: gpt56EffortIDs,
                    contextLimit: 1_050_000
                )
            )
        }

        return models
    }

    private static let gpt56EffortIDs = [
        "none",
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
    ]

    private static func model(
        id: String,
        displayName: String,
        effortIDs: [String],
        contextLimit: Int
    ) -> ProviderModelCapability {
        ProviderModelCapability(
            id: ProviderModelID(id),
            displayName: displayName,
            variants: effortIDs.map {
                ProviderVariant(
                    id: ProviderVariantID($0),
                    displayName: effortDisplayName(for: $0)
                )
            },
            contextLimit: contextLimit
        )
    }

    private static func effortDisplayName(for id: String) -> String {
        switch id {
        case "none":
            "None"
        case "xhigh":
            "XHigh"
        default:
            id.capitalized
        }
    }
}

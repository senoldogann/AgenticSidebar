import Foundation

struct ProviderID: Hashable, Codable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ProviderModelID: Hashable, Codable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ProviderVariantID: Hashable, Codable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ProviderVariant: Equatable, Sendable {
    let id: ProviderVariantID
    let displayName: String
}

struct ProviderModelCapability: Equatable, Sendable {
    let id: ProviderModelID
    let displayName: String
    let variants: [ProviderVariant]

    var supportsThinking: Bool {
        let nameLower = displayName.lowercased()
        let idLower = id.rawValue.lowercased()

        if variants.contains(where: { variant in
            let vName = variant.displayName.lowercased()
            let vID = variant.id.rawValue.lowercased()
            return vName.contains("thinking") || vName.contains("reasoning")
                || vID.contains("thinking") || vID.contains("reasoning")
        }) {
            return true
        }

        let thinkingTokens = [
            "r1", "reasoning", "thinking", "qwq", "o1", "o3",
            "deepseek-r1", "deepseek r1", "claude-3-7-sonnet",
            "flash-thinking"
        ]

        return thinkingTokens.contains { token in
            nameLower.contains(token) || idLower.contains(token)
        }
    }
}

struct ProviderCapabilities: Equatable, Sendable {
    let id: ProviderID
    let displayName: String
    let models: [ProviderModelCapability]

    func model(id: ProviderModelID) -> ProviderModelCapability? {
        models.first { $0.id == id }
    }

    func supports(
        variantID: ProviderVariantID?,
        for modelID: ProviderModelID
    ) -> Bool {
        guard let variantID else {
            return model(id: modelID) != nil
        }

        return model(id: modelID)?.variants.contains { $0.id == variantID } == true
    }
}

struct SessionConfiguration: Equatable, Codable, Sendable {
    var providerID: ProviderID
    var modelID: ProviderModelID
    var variantID: ProviderVariantID?
}

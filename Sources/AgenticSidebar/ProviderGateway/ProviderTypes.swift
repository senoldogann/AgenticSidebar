import Foundation

struct ProviderID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ProviderModelID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ProviderVariantID: Hashable, Sendable {
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

struct SessionConfiguration: Equatable, Sendable {
    var providerID: ProviderID
    var modelID: ProviderModelID
    var variantID: ProviderVariantID?
}

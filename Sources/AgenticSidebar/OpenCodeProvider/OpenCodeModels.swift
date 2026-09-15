import Foundation

struct OpenCodeModelReference: Equatable, Sendable {
    let providerID: String
    let modelID: String

    init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    init?(flattenedID: ProviderModelID) {
        let raw = flattenedID.rawValue
        guard
            let separator = raw.firstIndex(of: "/"),
            separator != raw.startIndex
        else {
            return nil
        }

        let modelStart = raw.index(after: separator)
        guard modelStart < raw.endIndex else {
            return nil
        }

        providerID = String(raw[..<separator])
        modelID = String(raw[modelStart...])
    }

    var flattenedID: ProviderModelID {
        ProviderModelID("\(providerID)/\(modelID)")
    }
}

enum OpenCodeAuthMethodType: String, Decodable, Equatable, Sendable {
    case api
    case oauth
}

struct OpenCodeAuthMethod: Decodable, Equatable, Sendable {
    let type: OpenCodeAuthMethodType
    let label: String
    let prompts: [OpenCodeAuthPrompt]?
}

struct OpenCodeAuthPrompt: Decodable, Equatable, Sendable {
    enum PromptType: String, Decodable, Equatable, Sendable {
        case text
        case select
    }

    let type: PromptType
    let key: String
    let message: String
    let placeholder: String?
    let options: [OpenCodeAuthOption]?
    let when: OpenCodeAuthCondition?
}

struct OpenCodeAuthOption: Decodable, Equatable, Sendable {
    let label: String
    let value: String
    let hint: String?
}

struct OpenCodeAuthCondition: Decodable, Equatable, Sendable {
    let key: String
    let op: String
    let value: String
}

struct OpenCodeProviderListResponse: Decodable, Sendable {
    let all: [OpenCodeProviderDescriptor]
    let connected: [String]
    let `default`: [String: String]
}

struct OpenCodeProviderDescriptor: Decodable, Sendable {
    let id: String
    let name: String
    let models: [String: OpenCodeModelDescriptor]
}

struct OpenCodeModelDescriptor: Decodable, Sendable {
    let id: String
    let providerID: String
    let name: String
    let variants: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case name
        case variants
    }

    private struct VariantKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decode(String.self, forKey: .providerID)
        name = try container.decode(String.self, forKey: .name)

        if container.contains(.variants) {
            let variantsContainer = try container.nestedContainer(
                keyedBy: VariantKey.self,
                forKey: .variants
            )
            variants = variantsContainer.allKeys.map(\.stringValue).sorted()
        } else {
            variants = []
        }
    }
}

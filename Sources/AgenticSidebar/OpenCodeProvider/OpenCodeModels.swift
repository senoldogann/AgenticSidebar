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
    /// `capabilities.reasoning`: model akıl yürütmeyi destekliyor mu
    /// (üst katalog bazen `variants` sözlüğünü boş bırakır; efor
    /// menüsü bu bayrakla geri doldurulur, yokluğu `false` sayılır).
    let supportsReasoning: Bool
    /// `limit.context`: modelin kabul ettiği en fazla girdi jetonu
    /// (OpenCode model kataloğu; yokluğu bilinmiyor demektir, uydurulmaz).
    let contextLimit: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case name
        case variants
        case capabilities
        case limit
    }

    private enum CapabilitiesKeys: String, CodingKey {
        case reasoning
    }

    private enum LimitKeys: String, CodingKey {
        case context
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

        // Biçim değişimine dayanıklıdır: `variants` sözlük ya da dizi
        // gelebilir; ikisi de okunur. Bozuk gelirse model çöpe gitmez,
        // varyantsız sayılır (efor menüsü `supportsReasoning` ile
        // geri doldurulabilir).
        if let names = try? container.decode([String].self, forKey: .variants) {
            variants = names.sorted()
        } else if let variantsContainer = try? container.nestedContainer(
            keyedBy: VariantKey.self,
            forKey: .variants
        ) {
            variants = variantsContainer.allKeys.map(\.stringValue).sorted()
        } else {
            variants = []
        }

        // `capabilities` yoksa ya da `reasoning` bool değilse `false`:
        // bilinmeyen yetenek uydurulmaz, efor menüsü boş kalır.
        if let capabilitiesContainer = try? container.nestedContainer(
            keyedBy: CapabilitiesKeys.self,
            forKey: .capabilities
        ) {
            supportsReasoning = (try? capabilitiesContainer.decode(Bool.self, forKey: .reasoning)) ?? false
        } else {
            supportsReasoning = false
        }

        // Sayı biçimi garanti değildir (katalog tam sayı, bazı sunucular
        // ondalık yazar); iki hâl de toleranslı okunur, yoksa `nil` kalır.
        if container.contains(.limit),
            let limitContainer = try? container.nestedContainer(keyedBy: LimitKeys.self, forKey: .limit)
        {
            if let context = try? limitContainer.decode(Int.self, forKey: .context) {
                contextLimit = context > 0 ? context : nil
            } else if let context = try? limitContainer.decode(Double.self, forKey: .context),
                context.isFinite, context > 0
            {
                contextLimit = Int(context)
            } else {
                contextLimit = nil
            }
        } else {
            contextLimit = nil
        }
    }
}

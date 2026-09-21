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
    /// Modelin en fazla girdi jetonu (bağlam penceresi). OpenCode `/provider`
    /// `limit.context`, OpenAI kataloğu model belgelerindeki değerdir.
    /// `nil` bilinmiyor demektir: halka gönderim bütçesine göre tahmini gösterir.
    let contextLimit: Int?

    init(
        id: ProviderModelID,
        displayName: String,
        variants: [ProviderVariant],
        contextLimit: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.variants = variants
        self.contextLimit = contextLimit
    }

    var supportsThinking: Bool {
        // Ad, kimlik ve varyantlar tek havuzda taranır: yetenek bazen
        // varyant adında yazar (`XHigh Thinking` gibi).
        let fields =
            [displayName, id.rawValue]
            + variants.flatMap { [$0.displayName, $0.id.rawValue] }
        let normalized = fields.map(Self.normalizedModelToken)

        // 1. Açık yetenek sözcükleri en güçlü sinyaldir.
        if normalized.contains(where: { $0.contains("thinking") || $0.contains("reasoning") }) {
            return true
        }
        // 2. Kısa kodlar yalnız bütün jeton olarak eşleşir: `deepseek-r1`
        // evet, `command-r` hayır. Çıplak alt-dize her şeyi yakalıyordu.
        let tokens = Set(normalized.flatMap { $0.split(separator: "-") }.map(String.init))
        if !tokens.isDisjoint(with: Self.thinkingCodes) {
            return true
        }
        // 3. Aile önekleri: akıl yürütmeyi bizzat taşıyan aileler.
        return normalized.contains { haystack in
            Self.thinkingFamilies.contains { haystack.contains($0) }
        }
    }

    /// Kısa akıl yürütme kodları: yalnız bütün jeton eşleşir. `r1` bilerek
    /// yoktur: `command-r1` gibi akıl yürütmeyen adları da yakalıyordu;
    /// DeepSeek akıl yürütmesi `deepseek-r1` ailesiyle kapsanır.
    private static let thinkingCodes: Set<String> = ["o1", "o3", "o4", "qwq"]

    /// Akıl yürütmeyi bizzat taşıyan aile önekleri (Eylül 2026 itibarıyla).
    /// Bilinçli olarak muhafazakârdır: listede yoksa rozet çıkmaz.
    /// Yeni aile eklerken `ProviderThinkingTests` genişletilir.
    private static let thinkingFamilies = [
        "deepseek-r1",
        "deepseek-reasoner",
        "qwen3",
        "claude-3-7",
        "claude-opus-4",
        "claude-sonnet-4",
        "claude-haiku-4",
        "gemini-2-5",
        "gemini-3",
        "gpt-5",
        "gpt-6",
        "grok-4",
    ]

    /// Ayraçlar (`-`, `_`, `.`, `/`, boşluk) tek tireye indirgenir:
    /// `Claude Sonnet 4.5` ile `claude-sonnet-4-5` aynı sayılır.
    static func normalizedModelToken(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var dashed = true
        for scalar in raw.lowercased() {
            if scalar.isLetter || scalar.isNumber {
                out.append(scalar)
                dashed = false
            } else if !dashed {
                out.append("-")
                dashed = true
            }
        }
        if out.hasSuffix("-") {
            out.removeLast()
        }
        return out
    }
}

struct ProviderCapabilities: Equatable, Sendable {
    let id: ProviderID
    let displayName: String
    let models: [ProviderModelCapability]

    func model(id: ProviderModelID) -> ProviderModelCapability? {
        if let exact = models.first(where: { $0.id == id }) {
            return exact
        }
        // Biçime dayanıklı yedek: katalog kimliği ile seçili kimlik aynı
        // modeli değişik yazımla taşıyabilir (`OpenAI/GPT-5` karşısında
        // `openai/gpt-5`). Birebir tutmazsa ayraç/harf normalizasyonuyla
        // denenir; o da tutmazsa `nil` (halka bilinmeyen gösterir).
        let wanted = ProviderModelCapability.normalizedModelToken(id.rawValue)
        return models.first {
            ProviderModelCapability.normalizedModelToken($0.id.rawValue) == wanted
        }
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

/// Provider-nötr izin yanıtı: `once` / `always` / `reject`.
///
/// Somut sağlayıcı yanıtıyla aynı ham değerleri taşır, böylece daha önce
/// `audit.jsonl` dosyasına yazılmış kayıtlar çözümlenmeye devam eder. Somut
/// sağlayıcı tipine bu katman içinden başvurulmaz; dönüşüm sınırda yapılır.
enum ProviderPermissionReply: String, Codable, Equatable, Sendable {
    case once
    case always
    case reject
}

/// Uygulamanın yönetilen dosyalarının konumu için sağlayıcı-nötr erişim.
///
/// `ManagedOpenCodeServerManager.managedWorkingDirectoryURL()` buraya delege
/// eder; SwiftUI sunum katmanı somut sunucu yöneticisine değil buna başvurur.
enum ManagedAppDirectories {
    static func openCodeWorkingDirectory() -> URL {
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return
            applicationSupport
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("OpenCode", isDirectory: true)
    }
}

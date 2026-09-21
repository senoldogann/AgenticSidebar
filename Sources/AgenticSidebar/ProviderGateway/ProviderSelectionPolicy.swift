import Foundation

/// Hangi sağlayıcı ve modelin varsayılan olacağına karar veren katman.
///
/// Bu bir ürün tercihidir, oturum çekirdeğinin işi değil: `AgentSession`
/// yalnızca "yapılandırma hâlâ geçerli mi" sorusunu sorar, "hangi model daha
/// iyi" sorusunun cevabı burada durur ve tek noktadan değiştirilir.
enum ProviderSelectionPolicy {
    /// Yerel ajan sağlayıcısı, uzak API'ye tercih edilir: araçları çalıştırabilen
    /// tek sağlayıcı odur.
    static let preferredProviderID = ProviderID("opencode")

    /// Model adında veya kimliğinde aranan parçalar.
    ///
    /// Aralarında öncelik yoktur: kazanan, sağlayıcının kendi sıralamasında bu
    /// parçalardan herhangi birini taşıyan ilk modeldir. Sıraya anlam yüklemek
    /// tercihi sessizce değiştirirdi.
    static let preferredModelTokens = [
        "deepseek v4",
        "deepseek v4.1 flash",
        "deepseek",
    ]

    /// Verilen yeteneklerden varsayılan yapılandırmayı seçer. Modeli olan hiçbir
    /// sağlayıcı yoksa `nil`.
    static func defaultConfiguration(
        from providers: [ProviderCapabilities]
    ) -> SessionConfiguration? {
        defaultConfiguration(from: providers, preferring: nil)
    }

    /// Kullanıcının genel seçimi (`preferring`) varsa ve modeli varsa o
    /// kazanır; yoksa ürün varsayılanı çalışır. `nil` tercih = seçim yok.
    static func defaultConfiguration(
        from providers: [ProviderCapabilities],
        preferring preferredProviderID: ProviderID?
    ) -> SessionConfiguration? {
        let usable = providers.filter { !$0.models.isEmpty }

        if let preferredProviderID,
            let provider = usable.first(where: { $0.id == preferredProviderID }),
            let model = preferredModel(in: provider)
        {
            return SessionConfiguration(
                providerID: provider.id,
                modelID: model.id,
                variantID: nil
            )
        }

        guard
            let provider = usable.first(where: { $0.id == Self.preferredProviderID })
                ?? usable.first
        else {
            return nil
        }

        guard let model = preferredModel(in: provider) else {
            return nil
        }

        return SessionConfiguration(
            providerID: provider.id,
            modelID: model.id,
            variantID: nil
        )
    }

    /// Sağlayıcının tercih edilen modeli; eşleşme yoksa ilk model.
    static func preferredModel(
        in provider: ProviderCapabilities
    ) -> ProviderModelCapability? {
        let preferred = provider.models.first { model in
            preferredModelTokens.contains { matches(model, token: $0) }
        }

        return preferred ?? provider.models.first
    }

    private static func matches(
        _ model: ProviderModelCapability,
        token: String
    ) -> Bool {
        model.displayName.localizedCaseInsensitiveContains(token)
            || model.id.rawValue.localizedCaseInsensitiveContains(token)
    }
}

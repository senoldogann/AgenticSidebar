import Foundation

/// Bestecideki bağlam halkasının tek girdisi: sağlayıcının bildirdiği
/// son girdi sayımı ve model penceresinin ne kadarı olduğu.
///
/// İki değer de sağlayıcıdan gelir, yerelde hesaplanmaz: pay son turun
/// bildirilen girdisidir (`TurnTokenUsage.inputTokens`), payda seçili
/// modelin gerçek penceresidir (`ProviderModelCapability.contextLimit`).
/// İkisinden biri yoksa halka bilinmeyen gösterir ("–"), tahmin uydurmaz.
struct SessionContextUsage: Equatable, Sendable {
    /// Sağlayıcının bildirdiği son girdi jetonu; bildirim yoksa `nil`.
    let usedTokens: Int?
    /// Model penceresi; sağlayıcı pencere vermiyorsa `nil`.
    let limitTokens: Int?
    /// Son turun gerçek sayımı (ipucu satırı için; yoksa `nil`).
    let lastInputTokens: Int?
    let lastOutputTokens: Int?

    /// 0…1 aralığında doluluk; pay ya da payda yoksa `nil`.
    var fraction: Double? {
        guard let usedTokens, let limitTokens, limitTokens > 0 else {
            return nil
        }
        return min(1, Double(usedTokens) / Double(limitTokens))
    }
}

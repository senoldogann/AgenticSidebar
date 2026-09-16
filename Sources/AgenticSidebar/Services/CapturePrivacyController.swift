import AppKit

/// Pencerenin ekran yakalamalarından gerçekte ne kadar korunabildiği.
///
/// `supportsSelfCaptureFiltering` alanı buradan kaldırıldı: `true` diyordu ama
/// açıklama metni hiçbir filtrenin uygulanmadığını söylüyordu ve bayrağı hiçbir
/// görünüm okumuyordu. Geriye ölçülebilir tek gerçek kaldı.
struct CapturePrivacyCapabilities: Equatable, Sendable {
    let externalCaptureExclusionGuaranteed: Bool
    let limitation: String

    static let current = CapturePrivacyCapabilities(
        externalCaptureExclusionGuaranteed: false,
        limitation: "macOS does not provide a supported API that guarantees this window is omitted from system screenshots or arbitrary third-party capture. This app performs no screen capture of its own, so no self-capture filtering is applied; ScreenCaptureKit filters could exclude the window only from captures the app itself initiates."
    )
}

struct CapturePrivacyReport: Equatable, Sendable {
    let externalCaptureExclusionApplied: Bool
    let capabilities: CapturePrivacyCapabilities
}

@MainActor
final class CapturePrivacyController {
    let capabilities = CapturePrivacyCapabilities.current

    @discardableResult
    func configure(window _: NSWindow) -> CapturePrivacyReport {
        CapturePrivacyReport(
            externalCaptureExclusionApplied: false,
            capabilities: capabilities
        )
    }
}

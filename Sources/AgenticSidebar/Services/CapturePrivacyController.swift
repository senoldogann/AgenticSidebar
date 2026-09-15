import AppKit

struct CapturePrivacyCapabilities: Equatable, Sendable {
    let externalCaptureExclusionGuaranteed: Bool
    let supportsSelfCaptureFiltering: Bool
    let limitation: String

    static let current = CapturePrivacyCapabilities(
        externalCaptureExclusionGuaranteed: false,
        supportsSelfCaptureFiltering: true,
        limitation: "macOS does not provide a supported API that guarantees this window is omitted from system screenshots or arbitrary third-party capture. ScreenCaptureKit filters can exclude this app from captures initiated by this app."
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

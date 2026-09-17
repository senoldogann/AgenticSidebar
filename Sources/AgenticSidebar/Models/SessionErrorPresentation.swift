import Foundation

/// User-facing presentation for `AgentSessionError`.
///
/// Messages stay deliberately free of backend error bodies and credential
/// material: they describe the actionable cause, never the raw response.
extension AgentSessionError {
    var message: String {
        switch self {
        case .missingCredential:
            "Add a provider credential in Settings to start a session."
        case .backendExecutableUnavailable:
            "The OpenCode executable was not found on this Mac."
        case .backendStartupFailure:
            "OpenCode could not be started. Check the OpenCode settings tab."
        case .authenticationFailure:
            "The provider rejected the stored credential."
        case .providerUnavailable:
            "The selected provider is unavailable right now."
        case .rateLimited:
            "The provider is rate limiting requests. Try again shortly."
        case .unsupportedCapability:
            "The selected provider, model, or reasoning level is not supported."
        case .transportFailure:
            "The connection to the provider failed."
        case .streamInterrupted:
            "The response ended before it completed."
        case .contextLimitExceeded:
            "This conversation no longer fits the model's context window. Start a new session to continue."
        case .unexpectedBackendResponse:
            // The provider's own words, when we kept them. A generic sentence
            // gives the user nothing to act on; the status and the body are
            // usually enough to tell a stale session from a rejected model.
            if let detail = ProviderResponseDiagnostics.shared.detail() {
                "Provider error: \(detail)"
            } else {
                "The provider returned an unreadable response. Check your provider settings or server logs."
            }
        }
    }

    var symbolName: String {
        switch self {
        case .missingCredential, .authenticationFailure:
            "key.slash"
        case .backendExecutableUnavailable, .backendStartupFailure:
            "terminal"
        case .providerUnavailable, .transportFailure:
            "antenna.radiowaves.left.and.right.slash"
        case .rateLimited:
            "hourglass"
        case .unsupportedCapability:
            "questionmark.circle"
        case .streamInterrupted:
            "exclamationmark.bubble"
        case .contextLimitExceeded:
            "arrow.down.right.and.arrow.up.left"
        case .unexpectedBackendResponse:
            "exclamationmark.triangle"
        }
    }
}

extension AgentSessionNotice {
    var message: String {
        switch self {
        case let .transcriptTrimmed(droppedMessageCount):
            "Earlier \(droppedMessageCount) message\(droppedMessageCount == 1 ? "" : "s") left out to fit the model context window."
        }
    }

    var symbolName: String {
        switch self {
        case .transcriptTrimmed:
            "scissors"
        }
    }
}

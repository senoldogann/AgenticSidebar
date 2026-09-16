import Foundation

/// One place decides how an HTTP status becomes a provider failure.
///
/// This is shared policy rather than an adapter detail, because the mapping is
/// what the user is told: a wrong answer here either hides a credential problem
/// behind a generic outage or invites a retry that can never succeed.
///
/// The one intentional divergence is `unauthorized`: OpenAI reports a rejected
/// API key as a *missing* credential (that is the fix the Settings tab offers),
/// while the OpenCode server distinguishes a rejected local server credential.
extension ProviderRuntimeError {
    static func forHTTPStatus(
        _ statusCode: Int,
        unauthorized: ProviderRuntimeError = .authenticationFailure
    ) -> ProviderRuntimeError {
        switch statusCode {
        case 401, 403:
            unauthorized
        case 429:
            .rateLimited
        case 500..<600:
            .unavailable
        default:
            .unexpectedResponse
        }
    }
}

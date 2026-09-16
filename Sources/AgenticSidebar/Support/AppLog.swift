import OSLog

/// Centralised, privacy-reviewed logging.
///
/// Rules for every call site:
/// - Never log prompt text, transcript contents, credentials, or request bodies.
/// - Log categorised failures (error cases, HTTP status codes, counts) instead of
///   silently swallowing them with `try?`.
enum AppLog {
    private static let subsystem = AppIdentity.bundleIdentifier

    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let agentSession = Logger(subsystem: subsystem, category: "AgentSession")
    static let openAI = Logger(subsystem: subsystem, category: "OpenAIProvider")
    static let openCode = Logger(subsystem: subsystem, category: "OpenCodeProvider")
    static let automation = Logger(subsystem: subsystem, category: "Automation")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let extensions = Logger(subsystem: subsystem, category: "Extensions")
}

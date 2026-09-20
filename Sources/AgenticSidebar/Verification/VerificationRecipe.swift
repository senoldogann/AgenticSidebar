import Foundation

/// One fixed-argv verification command in a trusted recipe.
///
/// `executable` is an absolute path and `arguments` stay separate `Process` arguments:
/// there is no shell anywhere in the verification path.
struct VerificationStep: Sendable, Codable, Equatable {
    let name: String
    let executable: String
    let arguments: [String]
    /// Workspace-relative working directory; a path that escapes the workspace is refused.
    let relativeWorkingDirectory: String
    let timeoutSeconds: TimeInterval
    let required: Bool
}

/// A step the resolver recognized but deliberately did not trust or could not run.
///
/// Recording the skip is what keeps a version mismatch visible instead of silently
/// substituting a different command.
struct VerificationStepSkip: Sendable, Codable, Equatable {
    let name: String
    let reason: String
}

/// Versioned, ordered set of commands trusted to verify one project revision.
struct VerificationRecipe: Sendable, Codable, Equatable {
    /// Human-readable identity recorded with every evidence entry.
    let name: String
    /// Recipe schema version; a consumer must not guess the semantics of an unknown version.
    let version: Int
    /// Project metadata the recipe was derived from, recorded for audit.
    let trustedSource: String
    let steps: [VerificationStep]
    /// Optional steps that were recognized but not trusted; the runner records them as skipped.
    let skippedSteps: [VerificationStepSkip]
}

import Foundation

enum ComposerReturnGesture: Equatable, Sendable {
    case plain
    case shifted
    case modified
}

enum ComposerSubmissionAvailability: Equatable, Sendable {
    case available
    case unavailable
}

enum ComposerReturnAction: Equatable, Sendable {
    case submit
    case insertNewline
    case suppress
    case systemDefault
}

enum ComposerSubmissionPolicy {
    static func action(
        for gesture: ComposerReturnGesture,
        availability: ComposerSubmissionAvailability
    ) -> ComposerReturnAction {
        switch gesture {
        case .plain:
            availability == .available ? .submit : .suppress
        case .shifted:
            .insertNewline
        case .modified:
            .systemDefault
        }
    }
}

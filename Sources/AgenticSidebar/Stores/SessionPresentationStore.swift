import Observation

@MainActor
@Observable
final class SessionPresentationStore {
    var state: SessionPresentationState

    init(state: SessionPresentationState = SessionPresentationState(phase: .idle)) {
        self.state = state
    }
}

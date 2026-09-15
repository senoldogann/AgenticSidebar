import Foundation
@testable import AgenticSidebar

struct TestProviderRuntime: ProviderRuntime {
    let id: ProviderID
    let capabilitySet: ProviderCapabilities
    let streamFactory: @Sendable (ProviderRequest) async throws -> ProviderStream

    init(
        id: ProviderID,
        displayName: String,
        models: [ProviderModelCapability],
        streamFactory: @escaping @Sendable (ProviderRequest) async throws -> ProviderStream = { _ in
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }
    ) {
        self.id = id
        self.capabilitySet = ProviderCapabilities(
            id: id,
            displayName: displayName,
            models: models
        )
        self.streamFactory = streamFactory
    }

    func capabilities() async throws -> ProviderCapabilities {
        capabilitySet
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        try await streamFactory(request)
    }
}

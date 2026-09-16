import XCTest
@testable import AgenticSidebar

@MainActor
final class AgentTodoRefreshTests: XCTestCase {
    func testOlderRefreshCannotOverwriteNewerTodoList() async {
        let runtime = ControlledTodoRuntime()
        let session = makeSession(runtime: runtime)
        let older = [AgentTodo(id: "old", content: "Old task", status: .pending)]
        let newer = [AgentTodo(id: "new", content: "New task", status: .inProgress)]

        session.refreshTodos()
        await runtime.waitForRequests(1)
        session.refreshTodos()
        await runtime.waitForRequests(2)

        await runtime.respond(to: 1, with: newer)
        for _ in 0..<100 where session.state.todos != newer {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.state.todos, newer)

        await runtime.respond(to: 0, with: older)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.state.todos, newer, "A late older result must never revert the task list")
    }

    func testPreviousTurnTodoResponseCannotRestoreClearedTasks() async throws {
        let runtime = ControlledTodoRuntime()
        let session = makeSession(runtime: runtime)
        session.refreshTodos()
        await runtime.waitForRequests(1)

        let turn = try XCTUnwrap(session.submit("Start a new task"))
        await turn.value
        await runtime.waitForRequests(2)

        await runtime.respond(
            to: 0,
            with: [AgentTodo(id: "previous", content: "Previous turn", status: .pending)]
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(session.state.todos.isEmpty, "The new turn must invalidate earlier requests")
        await runtime.respond(to: 1, with: [])
    }

    private func makeSession(runtime: ControlledTodoRuntime) -> AgentSession {
        AgentSession(
            runtimes: [runtime],
            state: AgentSessionState(
                configuration: SessionConfiguration(
                    providerID: ProviderID("alpha"),
                    modelID: ProviderModelID("alpha-1"),
                    variantID: nil
                )
            )
        )
    }
}

private actor ControlledTodoRuntime: ProviderRuntime {
    nonisolated let id = ProviderID("alpha")
    private var requests: [CheckedContinuation<[AgentTodo]?, Never>] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            id: id,
            displayName: "Alpha",
            models: [ProviderModelCapability(
                id: ProviderModelID("alpha-1"),
                displayName: "Alpha 1",
                variants: []
            )]
        )
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        return ProviderStream(events: pair.stream)
    }

    func sessionTodos(sessionID: UUID) async -> [AgentTodo]? {
        await withCheckedContinuation { continuation in
            requests.append(continuation)
            let ready = requestWaiters.filter { requests.count >= $0.0 }
            requestWaiters.removeAll { requests.count >= $0.0 }
            for (_, waiter) in ready {
                waiter.resume()
            }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func respond(to index: Int, with todos: [AgentTodo]) {
        requests[index].resume(returning: todos)
    }
}

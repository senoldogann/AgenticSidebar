import Foundation
import XCTest

@testable import AgenticSidebar

final class CodingAgentContractTests: XCTestCase {
    func testPrematureEOFWithoutTerminalEventTreatedAsInterruption() async {
        let (stream, continuation) = AsyncStream.makeStream(of: CodingAgentEvent.self)
        let taskID = UUID()
        let attemptID = UUID()

        continuation.yield(
            CodingAgentEvent(
                taskID: taskID,
                attemptID: attemptID,
                generation: 1,
                timestamp: Date(),
                kind: .started
            ))
        continuation.yield(
            CodingAgentEvent(
                taskID: taskID,
                attemptID: attemptID,
                generation: 1,
                timestamp: Date(),
                kind: .textDelta("Writing code...")
            ))
        // Premature EOF: finish without terminalSuccess or terminalError!
        continuation.finish()

        let run = CodingAgentRun(events: stream, cancel: {})
        var events: [CodingAgentEvent] = []
        for await event in run.events {
            events.append(event)
        }

        let hasTerminal = events.contains { event in
            switch event.kind {
            case .terminalSuccess, .terminalError:
                return true
            default:
                return false
            }
        }
        XCTAssertFalse(hasTerminal, "Stream should not have a terminal event")
        XCTAssertFalse(run.isTerminatedSuccessfully(events: events), "EOF without terminalSuccess must NOT be reported as success")
    }

    func testTerminalSuccessIsRecognized() async {
        let (stream, continuation) = AsyncStream.makeStream(of: CodingAgentEvent.self)
        let taskID = UUID()
        let attemptID = UUID()

        continuation.yield(
            CodingAgentEvent(
                taskID: taskID,
                attemptID: attemptID,
                generation: 1,
                timestamp: Date(),
                kind: .started
            ))
        continuation.yield(
            CodingAgentEvent(
                taskID: taskID,
                attemptID: attemptID,
                generation: 1,
                timestamp: Date(),
                kind: .terminalSuccess
            ))
        continuation.finish()

        let run = CodingAgentRun(events: stream, cancel: {})
        var events: [CodingAgentEvent] = []
        for await event in run.events {
            events.append(event)
        }

        XCTAssertTrue(run.isTerminatedSuccessfully(events: events))
    }

    func testTerminalErrorIsNotReportedAsSuccess() async {
        let (stream, continuation) = AsyncStream.makeStream(of: CodingAgentEvent.self)
        let taskID = UUID()
        let attemptID = UUID()

        continuation.yield(
            CodingAgentEvent(
                taskID: taskID,
                attemptID: attemptID,
                generation: 1,
                timestamp: Date(),
                kind: .terminalError("Compiler failed")
            ))
        continuation.finish()

        let run = CodingAgentRun(events: stream, cancel: {})
        var events: [CodingAgentEvent] = []
        for await event in run.events {
            events.append(event)
        }

        XCTAssertFalse(run.isTerminatedSuccessfully(events: events))
    }

    func testCancellationInvokesCancelHandler() async {
        let expectation = expectation(description: "cancel invoked")
        let (stream, continuation) = AsyncStream.makeStream(of: CodingAgentEvent.self)

        let run = CodingAgentRun(
            events: stream,
            cancel: {
                expectation.fulfill()
                continuation.finish()
            }
        )

        await run.cancel()
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testStaleEventFilteringRejectsMismatchedAttemptOrGeneration() {
        let taskID = UUID()
        let activeAttemptID = UUID()
        let staleAttemptID = UUID()

        let validEvent = CodingAgentEvent(
            taskID: taskID,
            attemptID: activeAttemptID,
            generation: 2,
            timestamp: Date(),
            kind: .textDelta("Valid")
        )

        let staleAttemptEvent = CodingAgentEvent(
            taskID: taskID,
            attemptID: staleAttemptID,
            generation: 2,
            timestamp: Date(),
            kind: .textDelta("Stale attempt")
        )

        let staleGenerationEvent = CodingAgentEvent(
            taskID: taskID,
            attemptID: activeAttemptID,
            generation: 1,
            timestamp: Date(),
            kind: .textDelta("Stale generation")
        )

        let wrongTaskEvent = CodingAgentEvent(
            taskID: UUID(),
            attemptID: activeAttemptID,
            generation: 2,
            timestamp: Date(),
            kind: .textDelta("Wrong task")
        )

        XCTAssertTrue(validEvent.matches(taskID: taskID, attemptID: activeAttemptID, generation: 2))
        XCTAssertFalse(staleAttemptEvent.matches(taskID: taskID, attemptID: activeAttemptID, generation: 2))
        XCTAssertFalse(staleGenerationEvent.matches(taskID: taskID, attemptID: activeAttemptID, generation: 2))
        XCTAssertFalse(wrongTaskEvent.matches(taskID: taskID, attemptID: activeAttemptID, generation: 2))
    }

    func testStreamBackpressureAndSequentialDelivery() async {
        // Bounded buffering guarantees order preservation without dropping events.
        let taskID = UUID()
        let attemptID = UUID()
        let totalCount = 100

        let (stream, continuation) = AsyncStream.makeStream(
            of: CodingAgentEvent.self,
            bufferingPolicy: .bufferingNewest(totalCount)
        )

        let run = CodingAgentRun(events: stream, cancel: {})

        // Produce events
        for i in 0..<totalCount {
            continuation.yield(
                CodingAgentEvent(
                    taskID: taskID,
                    attemptID: attemptID,
                    generation: 1,
                    kind: .textDelta("chunk-\(i)")
                ))
        }
        continuation.finish()

        // Consume events
        var receivedIndices: [Int] = []
        for await event in run.events {
            if case .textDelta(let text) = event.kind {
                let idxStr = text.replacingOccurrences(of: "chunk-", with: "")
                if let idx = Int(idxStr) {
                    receivedIndices.append(idx)
                }
            }
        }

        XCTAssertEqual(receivedIndices.count, totalCount)
        XCTAssertEqual(receivedIndices, Array(0..<totalCount), "Events must be delivered strictly sequentially")
    }
}

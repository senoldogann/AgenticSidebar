import Foundation
import XCTest
@testable import AgenticSidebar

/// The channel exists to bound memory: `AsyncThrowingStream` accepts every
/// element immediately, so these tests pin down that a producer waits instead of
/// buffering, and that no waiter survives a cancelled exchange.
final class BoundedChannelTests: XCTestCase {
    func testDeliversEveryElementInOrderAcrossABoundedBuffer() async throws {
        let channel = BoundedChannel<Int>(capacity: 2)
        let probe = SendProbe()

        let producer = Task {
            for value in 1...6 {
                try await channel.send(value)
                await probe.record(value)
            }
            await channel.finish()
        }

        let isFilled = await waitUntil(timeout: .seconds(5)) { await probe.count == 2 }
        XCTAssertTrue(
            isFilled,
            "The producer should fill the two-element buffer"
        )

        var received: [Int] = []
        for try await value in channel.makeStream() {
            received.append(value)
        }

        _ = await producer.result
        XCTAssertEqual(received, [1, 2, 3, 4, 5, 6])
    }

    func testProducerSuspendsWhileTheBufferIsFull() async throws {
        let channel = BoundedChannel<Int>(capacity: 1)
        let probe = SendProbe()

        let producer = Task {
            for value in 1...4 {
                try await channel.send(value)
                await probe.record(value)
            }
        }

        let reachedOne = await waitUntil(timeout: .seconds(5)) { await probe.count == 1 }
        XCTAssertTrue(reachedOne)

        // Give the producer every chance to run ahead; a bounded channel must
        // keep it parked on the full buffer.
        try await Task.sleep(for: .milliseconds(100))
        let countWhileBlocked = await probe.count
        XCTAssertEqual(countWhileBlocked, 1, "The producer must not outrun the buffer")

        let receivedFirst = try await channel.receive()
        XCTAssertEqual(receivedFirst, 1)
        let reachedTwo = await waitUntil(timeout: .seconds(5)) { await probe.count == 2 }
        XCTAssertTrue(reachedTwo)

        await channel.cancel()
        _ = await producer.result
    }

    func testFinishDeliversQueuedElementsThenEndsTheStream() async throws {
        let channel = BoundedChannel<String>(capacity: 4)
        try await channel.send("first")
        try await channel.send("second")
        await channel.finish()

        var received: [String] = []
        for try await element in channel.makeStream() {
            received.append(element)
        }

        XCTAssertEqual(received, ["first", "second"])
    }

    func testFinishPropagatesProducerFailure() async throws {
        let channel = BoundedChannel<String>(capacity: 4)
        try await channel.send("partial")
        await channel.finish(throwing: ProviderRuntimeError.transport)

        var received: [String] = []

        do {
            for try await element in channel.makeStream() {
                received.append(element)
            }
            XCTFail("Expected the stream to fail")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .transport)
        }

        XCTAssertEqual(received, ["partial"])
    }

    func testCancelReleasesAProducerBlockedOnAFullBuffer() async throws {
        let channel = BoundedChannel<Int>(capacity: 1)
        let probe = SendProbe()

        let producer = Task {
            for value in 1...5 {
                do {
                    try await channel.send(value)
                } catch {
                    await probe.recordFailure(error)
                    return
                }
                await probe.record(value)
            }
        }

        let reachedOne = await waitUntil(timeout: .seconds(5)) { await probe.count == 1 }
        XCTAssertTrue(reachedOne)
        await channel.cancel()
        _ = await producer.result

        let finalCount = await probe.count
        XCTAssertEqual(finalCount, 1, "Only the buffered element was accepted")
        let lastFailure = await probe.lastFailure
        XCTAssertTrue(lastFailure is CancellationError)
    }

    func testCancelReleasesAWaitingConsumer() async throws {
        let channel = BoundedChannel<Int>(capacity: 1)
        let probe = SendProbe()

        let consumer = Task {
            do {
                _ = try await channel.receive()
                await probe.recordFailure(nil)
            } catch {
                await probe.recordFailure(error)
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        await channel.cancel()
        _ = await consumer.result

        let lastFailure = await probe.lastFailure
        XCTAssertTrue(lastFailure is CancellationError)
    }

    func testSendingAfterFinishIsDroppedInsteadOfFailingTheProducer() async throws {
        let channel = BoundedChannel<Int>(capacity: 2)
        try await channel.send(1)
        await channel.finish()

        try await channel.send(2)

        let queuedCount = await channel.queuedCount
        XCTAssertEqual(queuedCount, 1)
    }

    private func waitUntil(
        timeout: Duration,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return false
    }
}

private actor SendProbe {
    private(set) var count = 0
    private(set) var values: [Int] = []
    private(set) var lastFailure: (any Error)?

    func record(_ value: Int) {
        count += 1
        values.append(value)
    }

    func recordFailure(_ error: (any Error)?) {
        lastFailure = error
    }
}

import Foundation

/// Bounded, single-producer/single-consumer async channel.
///
/// `AsyncThrowingStream` accepts every element a producer yields, so a fast
/// producer keeps buffering while the consumer is busy applying view state: a
/// long tool-heavy turn could grow that queue without limit. This channel
/// suspends the producer once `capacity` elements are queued, which bounds
/// memory and lets the consumer set the pace.
///
/// The channel is intentionally small: `send` never blocks the caller's actor
/// beyond a suspension, and both waiting sides are released when the exchange is
/// cancelled, so a torn-down consumer can never strand a producer.
actor BoundedChannel<Element: Sendable> {
    private enum Outcome {
        case open
        case finished(Error?)
    }

    private let capacity: Int
    private var buffer: [Element] = []
    private var receiveWaiter: CheckedContinuation<Element?, Error>?
    private var sendWaiters: [CheckedContinuation<Void, Error>] = []
    private var outcome: Outcome = .open

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// Number of elements currently waiting to be consumed.
    var queuedCount: Int {
        buffer.count
    }

    /// How many producers are suspended on a full buffer.
    ///
    /// Exposed for the same reason as the count of what the buffer holds: whether
    /// the producer is *suspended* is a property of this actor, and a test that
    /// guessed at it could only be timing-dependent. The back-pressure test tried
    /// to infer it from the buffer being full and lost the race on a slower
    /// machine, where the cancel arrived after the producer had already moved on.
    var blockedSenderCount: Int {
        sendWaiters.count
    }

    /// Enqueues an element, suspending while the buffer is at capacity.
    func send(_ element: Element) async throws {
        while true {
            if case .finished = outcome {
                // The consumer already stopped caring; drop the element rather
                // than failing the producer with an unrelated error.
                return
            }

            if let waiter = receiveWaiter {
                receiveWaiter = nil
                waiter.resume(returning: element)
                return
            }

            if buffer.count < capacity {
                buffer.append(element)
                return
            }

            try await waitForSpace()
        }
    }

    /// Ends the exchange normally. A queued element is still delivered; the
    /// consumer observes `nil` once the buffer is drained.
    func finish(throwing error: Error? = nil) {
        guard case .open = outcome else {
            return
        }

        outcome = .finished(error)
        resumeReceiverIfNeeded()
        resumeAllSenders(with: nil)
    }

    /// Ends the exchange from both ends: waiters fail with `CancellationError`
    /// instead of hanging forever.
    func cancel() {
        guard case .open = outcome else {
            return
        }

        outcome = .finished(CancellationError())
        resumeReceiverIfNeeded()
        resumeAllSenders(with: CancellationError())
    }

    /// Pull-based stream over the channel. Requesting the next element is what
    /// releases a producer blocked on a full buffer, and cancelling the stream
    /// releases every waiter.
    ///
    /// İptal kapsamı bilinçli olarak kanal geneli: tek bir alıcı ya da
    /// gönderici iptali bütün eşanjörü `CancellationError` ile kapatır. Bu
    /// tek-üretici/tek-tüketici tasarımında beklenen davranıştır; çoklayıcı
    /// kullanımda yeniden değerlendirilmelidir.
    nonisolated func makeStream() -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream(
            unfolding: { [self] in
                try await receive()
            }
        )
    }

    /// Returns the next element, or `nil` once a producer finished and the buffer
    /// is drained. Propagates the producer's error.
    func receive() async throws -> Element? {
        try await withTaskCancellationHandler {
            try await dequeue()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func dequeue() async throws -> Element? {
        if !buffer.isEmpty {
            let element = buffer.removeFirst()
            resumeSenderIfPossible()
            return element
        }

        if case .finished(let error) = outcome {
            if let error {
                throw error
            }
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            switch outcome {
            case .open:
                receiveWaiter = continuation
            case .finished(let error):
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func waitForSpace() async throws {
        if case .finished = outcome {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                switch outcome {
                case .open:
                    sendWaiters.append(continuation)
                case .finished:
                    continuation.resume(returning: ())
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func resumeReceiverIfNeeded() {
        guard let waiter = receiveWaiter else {
            return
        }

        receiveWaiter = nil
        if case .finished(let error) = outcome, let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: nil)
        }
    }

    private func resumeSenderIfPossible() {
        guard case .open = outcome, !sendWaiters.isEmpty else {
            return
        }

        let waiter = sendWaiters.removeFirst()
        waiter.resume(returning: ())
    }

    private func resumeAllSenders(with error: Error?) {
        let waiters = sendWaiters
        sendWaiters.removeAll()

        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: ())
            }
        }
    }
}

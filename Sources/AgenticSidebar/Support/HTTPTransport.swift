import Foundation

/// One non-streaming HTTP response: the status plus the raw body.
struct HTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

/// A streaming HTTP response: the status plus a pull-based sequence of lines.
///
/// The `cancel` closure tears the socket read down; a caller that stops early
/// must use it (or drain the stream) so a forwarding task cannot outlive its
/// turn and keep reading a backend nobody is listening to.
struct HTTPLineStream: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () async -> Void

    init(
        statusCode: Int,
        lines: AsyncThrowingStream<String, Error>,
        cancel: @escaping @Sendable () async -> Void = {}
    ) {
        self.statusCode = statusCode
        self.lines = lines
        self.cancel = cancel
    }
}

/// The provider-facing contract for talking HTTP to a backend.
///
/// Both adapters need the same four things from the network: a bounded read of a
/// whole response, a bounded line stream, cancellation that actually unblocks
/// the reader, and a uniform mapping of networking failures onto
/// `ProviderRuntimeError`. Each adapter keeps its own protocol name (and its
/// own fakes) by refining this one, while the types and the implementation live
/// here, so the two transports cannot drift apart again.
protocol ProviderHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func stream(_ request: URLRequest) async throws -> HTTPLineStream
}

/// The single `URLSession`-backed implementation of `ProviderHTTPTransport`.
struct URLSessionHTTPTransport: ProviderHTTPTransport {
    /// Lines buffered before the reader is asked to slow down. Shared by every
    /// adapter so back-pressure behaves identically on both paths.
    static let lineBufferCapacity = 256

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    /// A transport on a session tuned for long-lived streams rather than
    /// interactive requests. Each call builds its own session: this is not a
    /// process-wide singleton, and the name says so.
    static func streaming() -> Self {
        Self(session: StreamingURLSessionFactory.make())
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ProviderRuntimeError.unexpectedResponse
            }
            return HTTPResponse(statusCode: response.statusCode, data: data)
        } catch let error as ProviderRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderRuntimeError.transport
        }
    }

    func stream(_ request: URLRequest) async throws -> HTTPLineStream {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ProviderRuntimeError.unexpectedResponse
            }

            // A stream that accepts every line without pressing back on the
            // socket would buffer an entire response in memory whenever the
            // consumer is busy, so lines go through a bounded channel.
            let channel = BoundedChannel<String>(capacity: Self.lineBufferCapacity)
            let forwardingTask = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        try await channel.send(line)
                    }
                    await channel.finish()
                } catch is CancellationError {
                    await channel.finish(throwing: CancellationError())
                } catch {
                    await channel.finish(throwing: ProviderRuntimeError.transport)
                }
            }

            return HTTPLineStream(
                statusCode: response.statusCode,
                lines: channel.makeStream(),
                cancel: {
                    forwardingTask.cancel()
                    await channel.finish(throwing: CancellationError())
                }
            )
        } catch let error as ProviderRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderRuntimeError.transport
        }
    }
}

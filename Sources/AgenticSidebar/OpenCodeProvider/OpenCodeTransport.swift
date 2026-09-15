import Foundation

struct OpenCodeHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

struct OpenCodeLineStream: Sendable {
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

protocol OpenCodeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse
    func stream(_ request: URLRequest) async throws -> OpenCodeLineStream
}

struct URLSessionOpenCodeTransport: OpenCodeTransport {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    static func shared() -> Self {
        Self(session: .shared)
    }

    func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ProviderRuntimeError.unexpectedResponse
            }
            return OpenCodeHTTPResponse(statusCode: response.statusCode, data: data)
        } catch let error as ProviderRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderRuntimeError.transport
        }
    }

    func stream(_ request: URLRequest) async throws -> OpenCodeLineStream {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ProviderRuntimeError.unexpectedResponse
            }

            let pair = AsyncThrowingStream<String, Error>.makeStream()
            let forwardingTask = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        pair.continuation.yield(line)
                    }
                    pair.continuation.finish()
                } catch is CancellationError {
                    pair.continuation.finish(throwing: CancellationError())
                } catch {
                    pair.continuation.finish(throwing: ProviderRuntimeError.transport)
                }
            }

            return OpenCodeLineStream(
                statusCode: response.statusCode,
                lines: pair.stream,
                cancel: {
                    forwardingTask.cancel()
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

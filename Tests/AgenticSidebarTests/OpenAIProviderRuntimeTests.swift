import Foundation
import XCTest
@testable import AgenticSidebar

final class OpenAIProviderRuntimeTests: XCTestCase {
    func testCapabilitiesDiscoversAccessibleModelsThroughModelsEndpoint() async throws {
        let transport = MockOpenAITransport(
            sendResponse: OpenAIHTTPResponse(
                statusCode: 200,
                data: Data(
                    #"{"object":"list","data":[{"id":"gpt-5.6","object":"model","created":1,"owned_by":"openai"},{"id":"gpt-6-astra","object":"model","created":1,"owned_by":"openai"},{"id":"future-unverified-model","object":"model","created":1,"owned_by":"openai"}]}"#.utf8
                )
            )
        )
        let runtime = OpenAIProviderRuntime(
            transport: transport,
            credentialStore: StubCredentialStore(value: "test-key"),
            baseURL: URL(string: "https://example.test/v1")!
        )

        let capabilities = try await runtime.capabilities()

        XCTAssertEqual(capabilities.id, ProviderID("openai"))
        XCTAssertEqual(capabilities.displayName, "OpenAI")
        XCTAssertEqual(
            capabilities.models.map(\.id),
            [ProviderModelID("gpt-6-astra"), ProviderModelID("gpt-5.6")]
        )

        let recordedRequest = await transport.lastSendRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-key"
        )
    }

    func testCapabilitiesThrowsMissingCredentialWhenKeychainHasNoAPIKey() async {
        let runtime = OpenAIProviderRuntime(
            transport: MockOpenAITransport(),
            credentialStore: StubCredentialStore(value: nil),
            baseURL: URL(string: "https://example.test/v1")!
        )

        await XCTAssertThrowsErrorAsync(
            try await runtime.capabilities()
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .missingCredential)
        }
    }

    func testStartStreamNormalizesResponsesSSEEvents() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        linePair.continuation.yield(
            #"data: {"type":"response.output_text.delta","delta":"Hello"}"#
        )
        linePair.continuation.yield(
            #"data: {"type":"response.output_text.delta","delta":" world"}"#
        )
        linePair.continuation.yield(
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#
        )
        linePair.continuation.finish()

        let transport = MockOpenAITransport(
            streamResponse: OpenAILineStream(
                statusCode: 200,
                lines: linePair.stream
            )
        )
        let runtime = OpenAIProviderRuntime(
            transport: transport,
            credentialStore: StubCredentialStore(value: "test-key"),
            baseURL: URL(string: "https://example.test/v1")!
        )
        let request = ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-5.6"),
                variantID: ProviderVariantID("medium")
            ),
            messages: [ChatMessage(role: .user, text: "Hi")],
            speedMode: .normal
        )

        let stream = try await runtime.startStream(for: request)
        var events: [ProviderEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .assistantTextDelta("Hello"),
                .assistantTextDelta(" world"),
                .completed
            ]
        )

        let recordedRequest = await transport.lastStreamRequest()
        let sentRequest = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(sentRequest.url?.path, "/v1/responses")
        XCTAssertEqual(
            sentRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-key"
        )
    }

    func testProviderStreamCancellationCancelsUnderlyingTransportStream() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        let cancellationProbe = RuntimeCancellationProbe()
        let transport = MockOpenAITransport(
            streamResponse: OpenAILineStream(
                statusCode: 200,
                lines: linePair.stream,
                cancel: {
                    await cancellationProbe.record()
                    linePair.continuation.finish(throwing: CancellationError())
                }
            )
        )
        let runtime = OpenAIProviderRuntime(
            transport: transport,
            credentialStore: StubCredentialStore(value: "test-key"),
            baseURL: URL(string: "https://example.test/v1")!
        )
        let request = ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-5.6"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "Hi")],
            speedMode: .normal
        )

        let stream = try await runtime.startStream(for: request)
        await stream.cancel()

        let cancellationCount = await cancellationProbe.count()
        XCTAssertEqual(cancellationCount, 1)
    }
}

private struct StubCredentialStore: CredentialStore {
    let value: String?

    func contains(_ key: CredentialKey) throws -> Bool {
        value != nil
    }

    func read(_ key: CredentialKey) throws -> String? {
        value
    }

    func write(_ value: String, for key: CredentialKey) throws {}
    func delete(_ key: CredentialKey) throws {}
}

private actor MockOpenAITransport: OpenAITransport {
    private let sendResponse: OpenAIHTTPResponse
    private let streamResponse: OpenAILineStream
    private var sendRequest: URLRequest?
    private var streamRequest: URLRequest?

    init(
        sendResponse: OpenAIHTTPResponse = OpenAIHTTPResponse(
            statusCode: 200,
            data: Data(#"{"object":"list","data":[]}"#.utf8)
        ),
        streamResponse: OpenAILineStream? = nil
    ) {
        self.sendResponse = sendResponse

        if let streamResponse {
            self.streamResponse = streamResponse
        } else {
            let pair = AsyncThrowingStream<String, Error>.makeStream()
            pair.continuation.finish()
            self.streamResponse = OpenAILineStream(
                statusCode: 200,
                lines: pair.stream
            )
        }
    }

    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        sendRequest = request
        return sendResponse
    }

    func stream(_ request: URLRequest) async throws -> OpenAILineStream {
        streamRequest = request
        return streamResponse
    }

    func lastSendRequest() -> URLRequest? {
        sendRequest
    }

    func lastStreamRequest() -> URLRequest? {
        streamRequest
    }
}

private actor RuntimeCancellationProbe {
    private var cancellationCount = 0

    func record() {
        cancellationCount += 1
    }

    func count() -> Int {
        cancellationCount
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

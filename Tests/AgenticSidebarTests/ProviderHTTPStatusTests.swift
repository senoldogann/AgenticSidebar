import Foundation
import XCTest
@testable import AgenticSidebar

final class ProviderHTTPStatusTests: XCTestCase {
    func testOpenAIMapsRateLimitingAndServerErrorsToDistinctCauses() async {
        let expectations: [(Int, ProviderRuntimeError)] = [
            (401, .missingCredential),
            (403, .missingCredential),
            (429, .rateLimited),
            (500, .unavailable),
            (503, .unavailable),
            (400, .unexpectedResponse)
        ]

        for (statusCode, expected) in expectations {
            let runtime = OpenAIProviderRuntime(
                transport: StubStatusCodeOpenAITransport(statusCode: statusCode),
                credentialStore: StubAPIKeyStore(),
                baseURL: URL(string: "https://example.test/v1")!
            )

            await assertRuntimeError(expected, from: runtime)
        }
    }

    func testOpenCodeMapsRateLimitingAndServerErrorsToDistinctCauses() async {
        let expectations: [(Int, ProviderRuntimeError)] = [
            (401, .authenticationFailure),
            (429, .rateLimited),
            (503, .unavailable),
            (404, .unexpectedResponse)
        ]

        for (statusCode, expected) in expectations {
            let client = OpenCodeClient(
                transport: StubStatusCodeOpenCodeTransport(statusCode: statusCode),
                connection: OpenCodeServerConnection(
                    baseURL: URL(string: "http://127.0.0.1:51170")!,
                    username: "opencode",
                    password: "server-password"
                )
            )

            do {
                _ = try await client.capabilities()
                XCTFail("Expected capabilities to throw for status \(statusCode)")
            } catch {
                XCTAssertEqual(
                    error as? ProviderRuntimeError,
                    expected,
                    "Unexpected mapping for status \(statusCode)"
                )
            }
        }
    }

    func testOpenAIClassifiesAContextWindowOverflowFromTheErrorBody() async {
        XCTAssertTrue(
            OpenAIProviderRuntime.indicatesContextOverflow(
                statusCode: 400,
                bodyPreview: #"{"error":{"code":"context_length_exceeded"}}"#
            )
        )
        XCTAssertTrue(
            OpenAIProviderRuntime.indicatesContextOverflow(
                statusCode: 400,
                bodyPreview: "This model's maximum context length is 128000 tokens"
            )
        )
        XCTAssertFalse(
            OpenAIProviderRuntime.indicatesContextOverflow(
                statusCode: 400,
                bodyPreview: #"{"error":{"code":"invalid_request_error"}}"#
            )
        )
        XCTAssertFalse(
            OpenAIProviderRuntime.indicatesContextOverflow(
                statusCode: 401,
                bodyPreview: "context length exceeded"
            ),
            "Only bad-request responses are classified this way"
        )

        let runtime = OpenAIProviderRuntime(
            transport: StubStatusCodeOpenAITransport(
                statusCode: 400,
                body: #"{"error":{"code":"context_length_exceeded"}}"#
            ),
            credentialStore: StubAPIKeyStore(),
            baseURL: URL(string: "https://example.test/v1")!
        )

        do {
            _ = try await runtime.startStream(for: makeRequest())
            XCTFail("Expected the streaming request to fail")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .contextLimitExceeded)
        }
    }

    private func makeRequest() -> ProviderRequest {
        ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-5.6"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "Hi")],
            speedMode: .normal
        )
    }

    private func assertRuntimeError(
        _ expected: ProviderRuntimeError,
        from runtime: OpenAIProviderRuntime
    ) async {
        do {
            _ = try await runtime.capabilities()
            XCTFail("Expected capabilities to throw \(expected)")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, expected)
        }
    }
}

private struct StubAPIKeyStore: CredentialStore {
    func contains(_ key: CredentialKey) throws -> Bool { true }
    func read(_ key: CredentialKey) throws -> String? { "test-key" }
    func write(_ value: String, for key: CredentialKey) throws {}
    func delete(_ key: CredentialKey) throws {}
}

private struct StubStatusCodeOpenAITransport: OpenAITransport {
    let statusCode: Int
    var body: String = ""

    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        OpenAIHTTPResponse(statusCode: statusCode, data: Data(body.utf8))
    }

    func stream(_ request: URLRequest) async throws -> OpenAILineStream {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        if !body.isEmpty {
            pair.continuation.yield(body)
        }
        pair.continuation.finish()
        return OpenAILineStream(statusCode: statusCode, lines: pair.stream)
    }
}

private struct StubStatusCodeOpenCodeTransport: OpenCodeTransport {
    let statusCode: Int

    func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        OpenCodeHTTPResponse(statusCode: statusCode, data: Data())
    }

    func stream(_ request: URLRequest) async throws -> OpenCodeLineStream {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: statusCode, lines: pair.stream)
    }
}

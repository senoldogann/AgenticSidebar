import Foundation
import XCTest

@testable import AgenticSidebar

@MainActor
final class PromptAttachmentTests: XCTestCase {
    func testOpenAIRequestInlinesImagesAndDisablesResponseStorage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).write(to: imageURL)

        let noteURL = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: noteURL)

        let urlRequest = try OpenAIResponsesRequest.make(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test-token",
            providerRequest: makeRequest(
                text: "Look at this",
                attachmentPaths: [imageURL.path, noteURL.path]
            )
        )

        let object = try XCTUnwrap(jsonObject(from: urlRequest))
        XCTAssertEqual(object["store"] as? Bool, false)

        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)

        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2, "One text part plus one inlined image part")

        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        let text = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(text.contains("Look at this"))
        XCTAssertTrue(
            text.contains("notes.txt"),
            "Unsupported attachments must be reported to the model rather than dropped"
        )

        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        let imageURLValue = try XCTUnwrap(content[1]["image_url"] as? String)
        XCTAssertTrue(imageURLValue.hasPrefix("data:image/png;base64,"))
    }

    func testOpenAIRequestKeepsPlainStringContentWithoutImages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let noteURL = directory.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: noteURL)

        let urlRequest = try OpenAIResponsesRequest.make(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: "test-token",
            providerRequest: makeRequest(
                text: "Read this",
                attachmentPaths: [noteURL.path]
            )
        )

        let object = try XCTUnwrap(jsonObject(from: urlRequest))
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? String)
        XCTAssertTrue(content.hasPrefix("Read this"))
        XCTAssertTrue(content.contains("notes.md"))
    }

    func testOpenCodePromptListsAttachmentPathsForItsOwnAgent() async throws {
        let client = AttachmentRecordingOpenCodeClient()
        let runtime = OpenCodeProviderRuntime(
            serverManager: AttachmentStubServerManager(
                connection: OpenCodeServerConnection(
                    baseURL: URL(string: "http://127.0.0.1:51199")!,
                    username: "opencode",
                    password: "server-password"
                )
            ),
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let stream = try await runtime.startStream(
            for: makeRequest(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("anthropic/claude/opus"),
                text: "What is wrong in this screenshot?",
                attachmentPaths: ["/tmp/agentic-shot.png", "/tmp/agentic-log.txt"]
            )
        )
        await stream.cancel()

        let recordedPrompt = await client.lastPrompt()
        let prompt = try XCTUnwrap(recordedPrompt)
        XCTAssertTrue(prompt.contains("What is wrong in this screenshot?"))
        XCTAssertTrue(prompt.contains("/tmp/agentic-shot.png"))
        XCTAssertTrue(prompt.contains("/tmp/agentic-log.txt"))
    }

    func testSubmitPreservesEveryAttachmentPathOnTheUserMessage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("one.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let noteURL = directory.appendingPathComponent("two.txt")
        try Data("two".utf8).write(to: noteURL)

        let runtime = TestProviderRuntime(
            id: ProviderID("alpha"),
            displayName: "Alpha",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("alpha-1"),
                    displayName: "Alpha 1",
                    variants: []
                )
            ]
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(
            service.submit(
                "Two files",
                attachmentPaths: [imageURL.path, noteURL.path]
            )
        )
        await task.value

        let userMessage = try XCTUnwrap(service.state.messages.first)
        XCTAssertEqual(userMessage.attachmentPaths.count, 2)
        XCTAssertTrue(
            userMessage.attachmentPaths[0].contains("one"),
            "Dışarıdaki ek tur klasörüne sabitlenir, ad gövdesi korunur"
        )
        XCTAssertTrue(userMessage.attachmentPaths[1].contains("two"))
        XCTAssertTrue(
            userMessage.attachmentPaths.allSatisfy {
                FileManager.default.fileExists(atPath: $0)
            },
            "Tura giren her yol tur başında var olmalıdır"
        )
    }

    func testChatMessagePresenterCleansRawOCRAndBoilerplateFromScreenshotPrompt() {
        let rawPrompt = """
            [Screenshot captured: Ekran Resmi 2026-09-16.png]
            Extracted content from screenshot:
            \"\"\"
            Hello world! This is extracted OCR text from the image.
            12345
            \"\"\"

            Please inspect this screenshot carefully: infer intent, if there is a question or problem solve it and provide the direct answer, or describe what is shown.
            """

        let cleaned = ChatMessagePresenter.cleanUserDisplayText(from: rawPrompt, hasAttachments: true)
        XCTAssertEqual(cleaned, "")
    }

    func testChatMessagePresenterPreservesUserQueryWhenPresent() {
        let rawPrompt = """
            [Screenshot captured: test.png]
            Extracted content from screenshot:
            \"\"\"
            OCR TEXT
            \"\"\"

            Can you fix this compile error?
            """

        let cleaned = ChatMessagePresenter.cleanUserDisplayText(from: rawPrompt, hasAttachments: true)
        XCTAssertEqual(cleaned, "Can you fix this compile error?")
    }

    func testChatMessagePresenterSuppressesGenericAttachmentDraft() {
        let cleaned = ChatMessagePresenter.cleanUserDisplayText(
            from: "Please inspect the attached file.",
            hasAttachments: true
        )
        XCTAssertEqual(cleaned, "")
    }

    func testChatMessagePresenterPreservesNormalTextMessage() {
        let text = "Hello AI assistant!"
        let cleaned = ChatMessagePresenter.cleanUserDisplayText(from: text, hasAttachments: false)
        XCTAssertEqual(cleaned, text)
    }

    func testChatMessagePresenterUnwrapsWholeMessageUserTurnFrame() {
        let framed = "<user_turn>\nDerinlemesine bir review başlat\n</user_turn>"
        let cleaned = ChatMessagePresenter.cleanUserDisplayText(from: framed, hasAttachments: false)
        XCTAssertEqual(cleaned, "Derinlemesine bir review başlat")
    }

    func testChatMessagePresenterPreservesUserTurnMentionInsideText() {
        let text = "Sohbette <user_turn> etiketleri görünüyor, bunu düzelt"
        let cleaned = ChatMessagePresenter.cleanUserDisplayText(from: text, hasAttachments: false)
        XCTAssertEqual(cleaned, text)
    }

    func testChatMessagePresenterIgnoresEmptyUserTurnFrame() {
        let framed = "<user_turn>\n</user_turn>"
        let cleaned = ChatMessagePresenter.cleanUserDisplayText(from: framed, hasAttachments: false)
        XCTAssertEqual(cleaned, framed)
    }

    private func makeRequest(
        providerID: ProviderID = ProviderID("openai"),
        modelID: ProviderModelID = ProviderModelID("gpt-5.6"),
        text: String,
        attachmentPaths: [String]
    ) -> ProviderRequest {
        ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: providerID,
                modelID: modelID,
                variantID: nil
            ),
            messages: [
                ChatMessage(
                    role: .user,
                    text: text,
                    attachmentPaths: attachmentPaths
                )
            ],
            speedMode: .normal
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-tests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return directory
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }
}

private struct AttachmentStubServerManager: OpenCodeServerManaging {
    let connection: OpenCodeServerConnection?

    func status() async -> OpenCodeServerStatus {
        guard let connection else {
            return .stopped
        }
        return .running(version: "1.18.31", baseURL: connection.baseURL)
    }

    func start(computerUse: ComputerUseConfiguration?) async throws -> OpenCodeServerConnection {
        guard let connection else {
            throw ProviderRuntimeError.unavailable
        }
        return connection
    }

    func currentConnection() async -> OpenCodeServerConnection? {
        connection
    }

    func stop() async {}
}

private actor AttachmentRecordingOpenCodeClient: OpenCodeClientProtocol {
    private var prompts: [String] = []

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(id: ProviderID("opencode"), displayName: "OpenCode", models: [])
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] { [:] }

    func setAPIKey(
        providerID: String,
        key: String,
        metadata: [String: String]
    ) async throws {}

    func createSession() async throws -> String { "ses_attachment" }

    func deleteSession(sessionID: String) async throws {}

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws {
        let text = parts.compactMap { part -> String? in
            if case .text(let str) = part { return str }
            return nil
        }.joined(separator: "\n")
        prompts.append(text)
    }

    func abort(sessionID: String) async throws {}

    func replyPermission(requestID: String, reply: String) async throws {}

    func sessionTodos(sessionID: String) async throws -> [AgentTodo] {
        []
    }

    func mcpServerStatuses() async throws -> [String: OpenCodeMCPServerStatus] {
        [:]
    }

    func addMCPServer(
        name: String,
        config: OpenCodeMCPServerConfig
    ) async throws -> [String: OpenCodeMCPServerStatus] {
        [:]
    }

    func disconnectMCPServer(name: String) async throws {}

    func eventStream() async throws -> OpenCodeLineStream {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.yield(
            #"data: {"type":"session.status","properties":{"sessionID":"ses_attachment","status":{"type":"idle"}}}"#
        )
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
    }

    func lastPrompt() -> String? {
        prompts.last
    }
}

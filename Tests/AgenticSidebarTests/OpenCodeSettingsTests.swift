import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class OpenCodeSettingsTests: XCTestCase {
    func testRefreshReportsExecutableAndStoppedStateWithoutStartingServer() async {
        let manager = SettingsOpenCodeServerManager(connection: nil)
        let settings = OpenCodeSettings(
            executableLocator: SettingsOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            serverManager: manager,
            clientFactory: { _ in SettingsOpenCodeClient() }
        )

        await settings.refreshStatus()

        XCTAssertTrue(settings.isInstalled)
        XCTAssertEqual(settings.serverStatus, .stopped)
        let startCount = await manager.startCount()
        XCTAssertEqual(startCount, 0)
        XCTAssertTrue(settings.apiProviderIDs.isEmpty)
    }

    func testStartReportsVersionAndLoadsOnlyAPIAuthMethods() async throws {
        let connection = makeConnection()
        let manager = SettingsOpenCodeServerManager(
            connection: connection,
            version: "1.18.31"
        )
        let client = SettingsOpenCodeClient(
            authMethods: [
                "poe": [
                    OpenCodeAuthMethod(type: .oauth, label: "Login with Poe", prompts: nil),
                    OpenCodeAuthMethod(type: .api, label: "Manually enter API Key", prompts: nil)
                ],
                "github-copilot": [
                    OpenCodeAuthMethod(type: .oauth, label: "GitHub OAuth", prompts: nil)
                ]
            ]
        )
        let settings = OpenCodeSettings(
            executableLocator: SettingsOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            serverManager: manager,
            clientFactory: { _ in client }
        )

        let didStart = await settings.start()

        XCTAssertTrue(didStart)
        XCTAssertEqual(
            settings.serverStatus,
            .running(version: "1.18.31", baseURL: connection.baseURL)
        )
        XCTAssertEqual(settings.apiProviderIDs, ["poe"])
        XCTAssertEqual(settings.selectedProviderID, "poe")
        XCTAssertEqual(settings.selectedAPIMethod?.label, "Manually enter API Key")
        XCTAssertNil(settings.errorMessage)
    }

    func testSaveAPIKeyForwardsMetadataAndClearsSecretDraftWithoutPersistingIt() async throws {
        let connection = makeConnection()
        let manager = SettingsOpenCodeServerManager(connection: connection)
        let client = SettingsOpenCodeClient(
            authMethods: [
                "cloudflare-workers-ai": [
                    OpenCodeAuthMethod(
                        type: .api,
                        label: "API key",
                        prompts: [
                            OpenCodeAuthPrompt(
                                type: .text,
                                key: "accountId",
                                message: "Account ID",
                                placeholder: "account",
                                options: nil,
                                when: nil
                            )
                        ]
                    )
                ]
            ]
        )
        let settings = OpenCodeSettings(
            executableLocator: SettingsOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            serverManager: manager,
            clientFactory: { _ in client }
        )
        let didStart = await settings.start()
        XCTAssertTrue(didStart)
        settings.apiKeyDraft = "  provider-secret  "
        settings.metadataDrafts["accountId"] = "acct-123"

        let didSave = await settings.saveAPIKey()

        XCTAssertTrue(didSave)
        XCTAssertEqual(settings.apiKeyDraft, "")
        let submissions = await client.submissions()
        XCTAssertEqual(
            submissions,
            [
                SettingsOpenCodeSubmission(
                    providerID: "cloudflare-workers-ai",
                    key: "provider-secret",
                    metadata: ["accountId": "acct-123"]
                )
            ]
        )
    }

    func testSaveFailureUsesSafeMessageAndDoesNotEchoSecret() async {
        let connection = makeConnection()
        let client = SettingsOpenCodeClient(
            authMethods: [
                "poe": [OpenCodeAuthMethod(type: .api, label: "API key", prompts: nil)]
            ],
            setAPIKeyError: SettingsSensitiveError(
                message: "authorization=provider-secret"
            )
        )
        let settings = OpenCodeSettings(
            executableLocator: SettingsOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            serverManager: SettingsOpenCodeServerManager(connection: connection),
            clientFactory: { _ in client }
        )
        let didStart = await settings.start()
        XCTAssertTrue(didStart)
        settings.apiKeyDraft = "provider-secret"

        let didSave = await settings.saveAPIKey()

        XCTAssertFalse(didSave)
        XCTAssertEqual(settings.apiKeyDraft, "provider-secret")
        XCTAssertEqual(settings.errorMessage, "Could not update the OpenCode provider credential.")
        XCTAssertFalse(settings.errorMessage?.contains("provider-secret") ?? true)
    }

    func testStopTerminatesManagerAndClearsAuthState() async {
        let connection = makeConnection()
        let manager = SettingsOpenCodeServerManager(connection: connection)
        let client = SettingsOpenCodeClient(
            authMethods: [
                "poe": [OpenCodeAuthMethod(type: .api, label: "API key", prompts: nil)]
            ]
        )
        let settings = OpenCodeSettings(
            executableLocator: SettingsOpenCodeExecutableLocator(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
            ),
            serverManager: manager,
            clientFactory: { _ in client }
        )
        let didStart = await settings.start()
        XCTAssertTrue(didStart)
        settings.apiKeyDraft = "draft-secret"

        await settings.stop()

        XCTAssertEqual(settings.serverStatus, .stopped)
        XCTAssertTrue(settings.apiProviderIDs.isEmpty)
        XCTAssertNil(settings.selectedProviderID)
        XCTAssertEqual(settings.apiKeyDraft, "")
        let stopCount = await manager.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    private func makeConnection() -> OpenCodeServerConnection {
        OpenCodeServerConnection(
            baseURL: URL(string: "http://127.0.0.1:51190")!,
            username: "opencode",
            password: "server-password"
        )
    }
}

private struct SettingsOpenCodeExecutableLocator: OpenCodeExecutableLocating {
    let url: URL?
    func locate() -> URL? { url }
}

private actor SettingsOpenCodeServerManager: OpenCodeServerManaging {
    private var connection: OpenCodeServerConnection?
    private let version: String
    private var starts = 0
    private var stops = 0

    init(
        connection: OpenCodeServerConnection?,
        version: String = "1.18.31"
    ) {
        self.connection = connection
        self.version = version
    }

    func status() -> OpenCodeServerStatus {
        guard let connection else { return .stopped }
        return .running(version: version, baseURL: connection.baseURL)
    }

    func start() async throws -> OpenCodeServerConnection {
        starts += 1
        guard let connection else {
            throw ProviderRuntimeError.executableUnavailable
        }
        return connection
    }

    func currentConnection() -> OpenCodeServerConnection? {
        connection
    }

    func stop() {
        stops += 1
        connection = nil
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private struct SettingsOpenCodeSubmission: Equatable, Sendable {
    let providerID: String
    let key: String
    let metadata: [String: String]
}

private actor SettingsOpenCodeClient: OpenCodeClientProtocol {
    private let methodSet: [String: [OpenCodeAuthMethod]]
    private let setAPIKeyError: Error?
    private var recordedSubmissions: [SettingsOpenCodeSubmission] = []

    init(
        authMethods: [String: [OpenCodeAuthMethod]] = [:],
        setAPIKeyError: Error? = nil
    ) {
        self.methodSet = authMethods
        self.setAPIKeyError = setAPIKeyError
    }

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(id: ProviderID("opencode"), displayName: "OpenCode", models: [])
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] {
        methodSet
    }

    func setAPIKey(
        providerID: String,
        key: String,
        metadata: [String: String]
    ) async throws {
        if let setAPIKeyError { throw setAPIKeyError }
        recordedSubmissions.append(
            SettingsOpenCodeSubmission(
                providerID: providerID,
                key: key,
                metadata: metadata
            )
        )
    }

    func createSession() async throws -> String { "unused" }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        text: String
    ) async throws {}

    func abort(sessionID: String) async throws {}

    func eventStream() async throws -> OpenCodeLineStream {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
    }

    func submissions() -> [SettingsOpenCodeSubmission] {
        recordedSubmissions
    }
}

private struct SettingsSensitiveError: Error, Sendable {
    let message: String
}

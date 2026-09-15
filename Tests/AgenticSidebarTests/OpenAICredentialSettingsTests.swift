import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class OpenAICredentialSettingsTests: XCTestCase {
    func testExistingCredentialIsReportedWithoutLoadingSecretIntoDraft() {
        let store = InMemoryCredentialStore(initialValue: "existing-secret")

        let settings = OpenAICredentialSettings(credentialStore: store)

        XCTAssertTrue(settings.hasStoredCredential)
        XCTAssertTrue(settings.apiKeyDraft.isEmpty)
        XCTAssertNil(settings.errorMessage)
    }

    func testSaveWritesTrimmedCredentialAndClearsDraft() throws {
        let store = InMemoryCredentialStore()
        let settings = OpenAICredentialSettings(credentialStore: store)
        settings.apiKeyDraft = "  sk-test-value  "

        XCTAssertTrue(settings.save())

        XCTAssertEqual(try store.read(.openAIAPIKey), "sk-test-value")
        XCTAssertTrue(settings.apiKeyDraft.isEmpty)
        XCTAssertTrue(settings.hasStoredCredential)
        XCTAssertNil(settings.errorMessage)
    }

    func testDeleteRemovesCredentialAndClearsState() throws {
        let store = InMemoryCredentialStore(initialValue: "existing-secret")
        let settings = OpenAICredentialSettings(credentialStore: store)
        settings.apiKeyDraft = "replacement"

        XCTAssertTrue(settings.delete())

        XCTAssertNil(try store.read(.openAIAPIKey))
        XCTAssertTrue(settings.apiKeyDraft.isEmpty)
        XCTAssertFalse(settings.hasStoredCredential)
        XCTAssertNil(settings.errorMessage)
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(initialValue: String? = nil) {
        value = initialValue
    }

    func contains(_ key: CredentialKey) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }

    func read(_ key: CredentialKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ value: String, for key: CredentialKey) throws {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func delete(_ key: CredentialKey) throws {
        lock.lock()
        defer { lock.unlock() }
        value = nil
    }
}

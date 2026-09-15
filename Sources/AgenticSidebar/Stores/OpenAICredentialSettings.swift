import Foundation
import Observation

@MainActor
@Observable
final class OpenAICredentialSettings {
    @ObservationIgnored
    private let credentialStore: any CredentialStore

    var apiKeyDraft = ""
    private(set) var hasStoredCredential = false
    private(set) var errorMessage: String?

    init(credentialStore: any CredentialStore) {
        self.credentialStore = credentialStore
        refreshStatus()
    }

    func refreshStatus() {
        do {
            hasStoredCredential = try credentialStore.contains(.openAIAPIKey)
            errorMessage = nil
        } catch {
            hasStoredCredential = false
            errorMessage = "Unable to access the OpenAI API key in Keychain."
        }
    }

    @discardableResult
    func save() -> Bool {
        let value = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return false
        }

        do {
            try credentialStore.write(value, for: .openAIAPIKey)
            apiKeyDraft = ""
            hasStoredCredential = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Unable to save the OpenAI API key to Keychain."
            return false
        }
    }

    @discardableResult
    func delete() -> Bool {
        do {
            try credentialStore.delete(.openAIAPIKey)
            apiKeyDraft = ""
            hasStoredCredential = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Unable to delete the OpenAI API key from Keychain."
            return false
        }
    }
}

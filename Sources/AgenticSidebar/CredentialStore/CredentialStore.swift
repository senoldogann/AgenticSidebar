import Foundation

enum CredentialKey: String, Sendable {
    case openAIAPIKey = "openai.api-key"
}

protocol CredentialStore: Sendable {
    func contains(_ key: CredentialKey) throws -> Bool
    func read(_ key: CredentialKey) throws -> String?
    func write(_ value: String, for key: CredentialKey) throws
    func delete(_ key: CredentialKey) throws
}

enum CredentialStoreError: Error, Equatable, Sendable {
    case invalidStoredData
    case keychainStatus(OSStatus)
}

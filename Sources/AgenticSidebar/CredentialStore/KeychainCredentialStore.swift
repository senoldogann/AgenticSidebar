import Foundation
import Security

struct KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = AppIdentity.bundleIdentifier) {
        self.service = service
    }

    func contains(_ key: CredentialKey) throws -> Bool {
        var query = baseQuery(for: key)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    func read(_ key: CredentialKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                throw CredentialStoreError.invalidStoredData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    func write(_ value: String, for key: CredentialKey) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(for: key)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainStatus(addStatus)
            }
        default:
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(for key: CredentialKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue
        ]
    }
}

import Foundation
import Security

public nonisolated struct KeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.charkle.app.secrets") { self.service = service }

    public func read(_ key: String) throws -> Data? {
        var query = selector(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return output as? Data
    }

    public func save(_ data: Data, for key: String) throws {
        let query = selector(key)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        guard status == errSecItemNotFound else { return try check(status) }
        var new = query
        new[kSecValueData as String] = data
        try check(SecItemAdd(new as CFDictionary, nil))
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(selector(key) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func selector(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw LibraryDatabaseError(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status).")
        }
    }
}

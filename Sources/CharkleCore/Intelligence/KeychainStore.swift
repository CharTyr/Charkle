import Foundation
import Security

public nonisolated struct KeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.charkle.app.secrets") { self.service = service }

    public func exists(_ key: String) -> Bool {
        var query = selector(key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        return status == errSecSuccess
    }

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
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            // Recover from stale ACL items created by an older app signature/CDHash by replacing the entry.
            _ = SecItemDelete(query as CFDictionary)
        } else if status != errSecItemNotFound {
            try check(status)
            return
        }
        var new = query
        new[kSecValueData as String] = data
        new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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

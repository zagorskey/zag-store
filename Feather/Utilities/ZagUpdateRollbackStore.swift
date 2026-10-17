import Foundation
import Security

/// Highest accepted signed metadata sequence, isolated by update channel.
///
/// Do not call recordAccepted until signature, canonical JSON, channel, expiry,
/// and payload validation have all succeeded. A missing or corrupt Keychain
/// record fails closed rather than silently resetting rollback history.
enum ZagUpdateRollbackStore {
    enum StoreError: Error {
        case invalidChannel, invalidSequence, invalidStoredValue, keychain(OSStatus), rollback
    }

    static let service = "app.zagstore.ios.update-metadata-v2.rollback"

    static func account(for channel: String) throws -> String {
        guard ["stable", "beta", "nightly"].contains(channel) else {
            throw StoreError.invalidChannel
        }
        return "highest-sequence.\(channel)"
    }

    static func highestAccepted(channel: String) throws -> Int? {
        let account = try account(for: channel)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              let number = Int(string), number > 0,
              String(number) == string else {
            throw StoreError.invalidStoredValue
        }
        return number
    }

    /// Rejects older sequences. The same sequence may be re-read after a restart.
    /// A production implementation must also pin the digest for equal sequences.
    static func recordAccepted(sequence: Int, channel: String) throws {
        guard sequence > 0 else { throw StoreError.invalidSequence }
        let account = try account(for: channel)
        if let highest = try highestAccepted(channel: channel), sequence < highest {
            throw StoreError.rollback
        }
        let value = Data(String(sequence).utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var add = identity
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else { throw StoreError.keychain(addStatus) }
        let update: [String: Any] = [kSecValueData as String: value]
        let status = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }
}

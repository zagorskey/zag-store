import Foundation
import Security

/// Isolated, disposable keychain probe for a future explicitly confirmed
/// in-place update. Never accesses application credentials or certificates.
enum ZagSelfUpdateKeychainProbe {
    private static let service = "app.zagstore.self-update.continuity-probe.v1"
    private static let account = "temporary-test-marker"

    enum ProbeError: LocalizedError {
        case keychainStatus(OSStatus)
        case missingMarker
        case invalidMarker

        var errorDescription: String? {
            switch self {
            case .keychainStatus(let status): return "Keychain operation failed (OSStatus \(status))."
            case .missingMarker: return "No continuity marker exists. Create one before the update."
            case .invalidMarker: return "The saved marker could not be decoded."
            }
        }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    /// Write a unique marker only when none exists; never overwrite one.
    static func createIfMissing() throws -> String {
        if let existing = try read() { return existing }
        let marker = UUID().uuidString
        var attributes = query
        attributes[kSecValueData as String] = Data(marker.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProbeError.keychainStatus(status) }
        return marker
    }

    static func read() throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProbeError.keychainStatus(status) }
        guard let data = result as? Data,
              let marker = String(data: data, encoding: .utf8),
              UUID(uuidString: marker) != nil else {
            throw ProbeError.invalidMarker
        }
        return marker
    }

    /// Read-only: return the actual keychain access group assigned to our
    /// disposable continuity marker. This does not inspect user credentials.
    /// A matching group is necessary, but not sufficient, to prove an upgrade
    /// will preserve keychain access.
    static func markerAccessGroup() throws -> String? {
        var attributes = query
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProbeError.keychainStatus(status) }
        guard let values = result as? [String: Any],
              let group = values[kSecAttrAccessGroup as String] as? String,
              !group.isEmpty else {
            throw ProbeError.invalidMarker
        }
        return group
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProbeError.keychainStatus(status)
        }
    }
}

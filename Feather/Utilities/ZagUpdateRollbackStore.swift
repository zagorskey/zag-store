import Foundation
import Security
import CryptoKit

/// Staged, per-channel rollback state. Call only after verifying the signed
/// envelope and validating its payload. Not connected to live updates.
actor ZagUpdateRollbackStore {
    static let shared = ZagUpdateRollbackStore()

    enum StoreError: Error, LocalizedError {
        case invalidChannel, invalidSequence, invalidStoredValue
        case keychain(OSStatus), rollback, conflictingSequence

        var errorDescription: String? {
            switch self {
            case .invalidChannel: return "This update channel isn't supported."
            case .invalidSequence: return "The update information has an invalid sequence number."
            case .invalidStoredValue: return "Zag Store's saved update history is unreadable."
            case .keychain(let status): return "Zag Store couldn't access its saved update history (\(status))."
            case .rollback: return "The published update information is older than information this device has already accepted."
            case .conflictingSequence: return "The published update information conflicts with information this device has already accepted."
            }
        }
    }

    private let service: String

    init(service: String = "app.zagstore.ios.update-metadata-v2.rollback") {
        self.service = service
    }

    private func account(for channel: String) throws -> String {
        guard ["stable", "beta", "nightly"].contains(channel) else {
            throw StoreError.invalidChannel
        }
        return "highest-sequence.\(channel)"
    }

    private struct Record: Codable {
        let sequence: Int
        let payloadSHA256: String
    }

    private func read(account: String) throws -> Record? {
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
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.sequence > 0,
              record.payloadSHA256.count == 64,
              record.payloadSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            // Old sequence-only records cannot safely be upgraded without
            // knowing the signed payload; do not silently reset history.
            throw StoreError.invalidStoredValue
        }
        return record
    }

    func highestAccepted(channel: String) throws -> Int? {
        try read(account: account(for: channel))?.sequence
    }

    /// Serialized within this app process by the actor. Same sequence must
    /// identify exactly the same signed payload bytes.
    ///
    /// Keychain does not offer compare-and-swap: this actor does NOT provide
    /// cross-process atomicity. Do not use from multiple processes.
    func recordAccepted(sequence: Int, payload: Data, channel: String) throws {
        guard sequence > 0, !payload.isEmpty else { throw StoreError.invalidSequence }
        let account = try account(for: channel)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        if let current = try read(account: account) {
            if sequence < current.sequence { throw StoreError.rollback }
            if sequence == current.sequence {
                guard digest == current.payloadSHA256 else {
                    throw StoreError.conflictingSequence
                }
                return
            }
        }
        let record = Record(sequence: sequence, payloadSHA256: digest)
        let value = try JSONEncoder().encode(record)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var add = identity
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw StoreError.keychain(status) }
        let update: [String: Any] = [kSecValueData as String: value]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else { throw StoreError.keychain(updateStatus) }
    }
}

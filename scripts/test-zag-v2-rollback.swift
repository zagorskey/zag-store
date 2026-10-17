import Foundation
import Security

// Exercises the actual Keychain-backed actor. Uses a disposable namespace;
// no production rollback records are read or changed.
@main
struct RollbackBehaviorTests {
    static func main() async throws {
        let service = "app.zagstore.ios.rollback-test.\(UUID().uuidString)"
        let store = ZagUpdateRollbackStore(service: service)
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("WARNING: disposable test Keychain cleanup failed: \(status)")
            }
        }
        var failures = 0
        func check(_ name: String, _ success: Bool) {
            print("\(success ? "PASS" : "FAIL"): \(name)")
            if !success { failures += 1 }
        }
        let a = Data("signed-payload-A".utf8)
        let b = Data("signed-payload-B".utf8)
        check("empty beta history", try await store.highestAccepted(channel: "beta") == nil)
        try await store.recordAccepted(sequence: 4, payload: a, channel: "beta")
        check("first acceptance", try await store.highestAccepted(channel: "beta") == 4)
        try await store.recordAccepted(sequence: 4, payload: a, channel: "beta")
        check("identical repeat accepted", try await store.highestAccepted(channel: "beta") == 4)
        do {
            try await store.recordAccepted(sequence: 3, payload: a, channel: "beta")
            check("older sequence rejected", false)
        } catch ZagUpdateRollbackStore.StoreError.rollback {
            check("older sequence rejected", true)
        }
        do {
            try await store.recordAccepted(sequence: 4, payload: b, channel: "beta")
            check("equal sequence substitution rejected", false)
        } catch ZagUpdateRollbackStore.StoreError.conflictingSequence {
            check("equal sequence substitution rejected", true)
        }
        try await store.recordAccepted(sequence: 5, payload: b, channel: "beta")
        check("higher sequence accepted", try await store.highestAccepted(channel: "beta") == 5)
        try await store.recordAccepted(sequence: 1, payload: a, channel: "stable")
        try await store.recordAccepted(sequence: 2, payload: b, channel: "nightly")
        check("stable history independent", try await store.highestAccepted(channel: "stable") == 1)
        check("nightly history independent", try await store.highestAccepted(channel: "nightly") == 2)
        check("beta history unchanged", try await store.highestAccepted(channel: "beta") == 5)
        do {
            try await store.recordAccepted(sequence: 1, payload: a, channel: "unknown")
            check("invalid channel rejected", false)
        } catch ZagUpdateRollbackStore.StoreError.invalidChannel {
            check("invalid channel rejected", true)
        }
        guard failures == 0 else { exit(1) }
        print("SUCCESS: Keychain-backed rollback behavior tests passed")
    }
}

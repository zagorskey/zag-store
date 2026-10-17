import Foundation
import CryptoKit
import Security

// Exercises the real staged pipeline and its Keychain actor with a disposable
// Ed25519 key and disposable Keychain service. No production release data used.
@main
struct VerifiedPipelineTests {
    static func main() async throws {
        let service = "app.zagstore.ios.pipeline-test.\(UUID().uuidString)"
        let store = ZagUpdateRollbackStore(service: service)
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("WARNING: disposable Keychain cleanup failed: \(status)")
            }
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let trustedKeys = ["test-key": privateKey.publicKey.rawRepresentation]
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        var failures = 0

        func check(_ name: String, _ success: Bool) {
            print("\(success ? "PASS" : "FAIL"): \(name)")
            if !success { failures += 1 }
        }

        func envelope(sequence: Int, notes: String = "Test", expiry: String = "2026-10-18T00:00:00Z", key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
            let payload: [String: Any] = [
                "schema": 2, "appId": "app.zagstore.ios", "channel": "beta",
                "sequence": sequence, "version": "1.0.0", "build": "3",
                "minimumIOSVersion": "16.0",
                "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa",
                "sha256": String(repeating: "a", count: 64),
                "releaseNotes": notes, "publishedAt": "2026-10-17T00:00:00Z",
                "expiresAt": expiry
            ]
            let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            let signature = try (key ?? privateKey).signature(for: ZagUpdateMetadataV2.domain + raw)
            let wrapper: [String: Any] = [
                "schema": 2, "keyId": "test-key",
                "payload": raw.base64EncodedString(),
                "signature": signature.base64EncodedString()
            ]
            return try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        func accept(_ data: Data) async throws {
            _ = try await ZagUpdateVerifiedPipeline.accept(
                envelope: data, channel: "beta",
                trustedKeys: trustedKeys, store: store, now: now
            )
        }

        try await accept(envelope(sequence: 4))
        check("valid signed payload advances rollback state",
              try await store.highestAccepted(channel: "beta") == 4)

        do {
            try await accept(envelope(sequence: 5, key: Curve25519.Signing.PrivateKey()))
            check("invalid signature rejected", false)
        } catch {
            check("invalid signature rejected", true)
        }
        check("invalid signature did not advance state",
              try await store.highestAccepted(channel: "beta") == 4)

        do {
            try await accept(envelope(sequence: 5, expiry: "2026-10-17T06:00:00Z"))
            check("expired payload rejected", false)
        } catch {
            check("expired payload rejected", true)
        }
        check("expired payload did not advance state",
              try await store.highestAccepted(channel: "beta") == 4)

        do {
            try await accept(envelope(sequence: 3))
            check("older signed sequence rejected", false)
        } catch ZagUpdateRollbackStore.StoreError.rollback {
            check("older signed sequence rejected", true)
        }
        check("rollback rejection preserved state",
              try await store.highestAccepted(channel: "beta") == 4)

        do {
            try await accept(envelope(sequence: 4, notes: "Changed"))
            check("equal sequence substitution rejected", false)
        } catch ZagUpdateRollbackStore.StoreError.conflictingSequence {
            check("equal sequence substitution rejected", true)
        }
        check("conflicting sequence preserved state",
              try await store.highestAccepted(channel: "beta") == 4)

        try await accept(envelope(sequence: 5))
        check("higher valid signed sequence accepted",
              try await store.highestAccepted(channel: "beta") == 5)

        guard failures == 0 else { exit(1) }
        print("SUCCESS: authenticated v2 pipeline integration tests passed")
    }
}

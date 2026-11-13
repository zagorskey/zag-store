import Foundation
import CryptoKit
import Security

// Regression for 13 November 2026: the Beta manifest expired and installed
// builds showed "ZagUpdateMetadataV2.ValidationError error 3". Expiry must
// still be rejected, but reported as expiry, and must never move rollback
// state. Disposable Ed25519 key and Keychain service; no production data.
@main
struct ExpiryRegressionTests {
    static func main() async throws {
        let service = "app.zagstore.ios.expiry-test.\(UUID().uuidString)"
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
        let iso = ISO8601DateFormatter()
        let published = "2026-10-25T04:00:23Z"
        let expires = "2026-11-01T04:00:23Z"
        var failures = 0

        func check(_ name: String, _ success: Bool) {
            print("\(success ? "PASS" : "FAIL"): \(name)")
            if !success { failures += 1 }
        }

        func envelope(sequence: Int, publishedAt: String = published, expiresAt: String = expires) throws -> Data {
            let payload: [String: Any] = [
                "schema": 2, "appId": "app.zagstore.ios", "channel": "beta",
                "sequence": sequence, "version": "1.0.0", "build": "2",
                "minimumIOSVersion": "16.4",
                "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa",
                "sha256": String(repeating: "a", count: 64),
                "releaseNotes": "Test", "publishedAt": publishedAt, "expiresAt": expiresAt
            ]
            let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            let signature = try privateKey.signature(for: ZagUpdateMetadataV2.domain + raw)
            let wrapper: [String: Any] = [
                "schema": 2, "keyId": "test-key",
                "payload": raw.base64EncodedString(),
                "signature": signature.base64EncodedString()
            ]
            return try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        func outcome(_ data: Data, at now: Date) async -> Error? {
            do {
                _ = try await ZagUpdateVerifiedPipeline.accept(
                    envelope: data, channel: "beta", trustedKeys: trustedKeys, store: store, now: now
                )
                return nil
            } catch {
                return error
            }
        }

        func isValidation(_ error: Error?, _ expected: ZagUpdateMetadataV2.ValidationError) -> Bool {
            guard let error = error as? ZagUpdateMetadataV2.ValidationError else { return false }
            return error == expected
        }

        // The failure seen on devices: a correctly signed manifest after its expiry.
        let expired = try envelope(sequence: 4)
        let thirteenDaysLater = iso.date(from: "2026-11-13T14:00:00Z")!
        let expiredError = await outcome(expired, at: thirteenDaysLater)
        check("expired manifest is still rejected", expiredError != nil)
        check("expired manifest is reported as expired", isValidation(expiredError, .expired))
        let message = expiredError?.localizedDescription ?? ""
        check("expired message is readable", message.contains("expired") && !message.contains("ZagUpdateMetadataV2"))
        check("expired manifest leaves rollback state untouched",
              try await store.highestAccepted(channel: "beta") == nil)

        // Exact boundary: expiresAt itself is already expired.
        check("manifest is expired at exactly expiresAt",
              isValidation(await outcome(expired, at: iso.date(from: expires)!), .expired))

        // The same manifest inside its window is accepted.
        let inside = await outcome(expired, at: iso.date(from: "2026-10-31T12:00:00Z")!)
        check("manifest inside its window is accepted", inside == nil)
        check("accepted manifest records its sequence", try await store.highestAccepted(channel: "beta") == 4)

        // A renewed successor with a higher sequence is accepted after the outage.
        let renewed = try envelope(sequence: 5, publishedAt: "2026-11-13T13:00:00Z", expiresAt: "2026-11-19T13:00:00Z")
        check("renewed successor is accepted after expiry", await outcome(renewed, at: thirteenDaysLater) == nil)
        check("renewed successor advances rollback state", try await store.highestAccepted(channel: "beta") == 5)

        // Clock behind publication.
        let future = try envelope(sequence: 6, publishedAt: "2026-11-20T00:00:00Z", expiresAt: "2026-11-26T00:00:00Z")
        check("manifest published in the future is not yet valid",
              isValidation(await outcome(future, at: thirteenDaysLater), .notYetValid))

        // Structural window rules are unchanged: more than seven days is invalid, not expired.
        let tooLong = try envelope(sequence: 7, publishedAt: "2026-11-13T00:00:00Z", expiresAt: "2026-11-21T00:00:01Z")
        check("validity window over seven days is still invalidPayload",
              isValidation(await outcome(tooLong, at: thirteenDaysLater), .invalidPayload))
        check("rejected manifests did not move rollback state", try await store.highestAccepted(channel: "beta") == 5)

        // Shipped builds report errors by position; the new cases are appended.
        check("invalidPayload keeps error code 3",
              (ZagUpdateMetadataV2.ValidationError.invalidPayload as NSError).code == 3)
        check("expired is error code 4", (ZagUpdateMetadataV2.ValidationError.expired as NSError).code == 4)

        if failures > 0 {
            print("\(failures) failed")
            exit(1)
        }
        print("All expiry regression checks passed")
    }
}

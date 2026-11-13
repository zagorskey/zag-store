import Foundation
import CryptoKit
import Security

// Rehearses a locally signed manifest against the application's actual
// production trust anchor, without changing live update discovery.
// Uses a unique disposable Keychain namespace (never the user's live state).
@main
struct ProductionKeyInterop {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: test-zag-v2-production-key-interop <rehearsal-envelope.json>\n", stderr)
            exit(2)
        }
        let envelope = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let keyID = "zag-v2-2026-b"
        let expectedFingerprint = "844fe8a9856d5e7ebc09c94f5d73acb8e61fb0d26a40d6533e3d9ee65616efa0"
        guard let key = ZagUpdateTrustStore.publicKey(for: keyID),
              key.count == 32,
              Data(SHA256.hash(data: key)).map({ String(format: "%02x", $0) }).joined() == expectedFingerprint else {
            fatalError("Installed trust anchor missing or mismatched")
        }
        print("PASS: app trust anchor matches reviewed production fingerprint")

        let service = "app.zagstore.ios.production-rehearsal.\(UUID().uuidString)"
        let store = ZagUpdateRollbackStore(service: service)
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        let now = Date()
        let accepted = try await ZagUpdateVerifiedPipeline.accept(
            envelope: envelope, channel: "beta",
            trustedKeys: ZagUpdateTrustStore.productionKeys,
            store: store, now: now
        )
        guard accepted.sequence == 1,
              accepted.appId == "app.zagstore.ios",
              try await store.highestAccepted(channel: "beta") == 1 else {
            fatalError("Production-key rehearsal was not accepted")
        }
        print("PASS: production-key Python envelope accepted by actual Swift pipeline")
        let raw = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
        func canonical(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        var badSignature = raw
        badSignature["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        var badPayload = raw
        badPayload["payload"] = Data("{}".utf8).base64EncodedString()
        var badKey = raw
        badKey["keyId"] = "disposable-python-jcs"
        let attempts: [(String, Data, String)] = [
            ("forged signature", try canonical(badSignature), "beta"),
            ("tampered payload", try canonical(badPayload), "beta"),
            ("untrusted key ID", try canonical(badKey), "beta"),
            ("wrong channel", envelope, "stable")
        ]
        for (label, data, channel) in attempts {
            do {
                _ = try await ZagUpdateVerifiedPipeline.accept(
                    envelope: data, channel: channel,
                    trustedKeys: ZagUpdateTrustStore.productionKeys,
                    store: store, now: now
                )
                fatalError("Unsafe envelope accepted: \(label)")
            } catch ZagUpdateMetadataV2.ValidationError.invalidEnvelope {
                print("PASS: \(label) rejected")
            } catch ZagUpdateMetadataV2.ValidationError.untrustedKey {
                print("PASS: \(label) rejected")
            } catch ZagUpdateMetadataV2.ValidationError.invalidSignature {
                print("PASS: \(label) rejected")
            } catch ZagUpdateMetadataV2.ValidationError.invalidPayload {
                print("PASS: \(label) rejected")
            } catch {
                fatalError("Unexpected error for \(label): \(error)")
            }
        }
        guard try await store.highestAccepted(channel: "beta") == 1,
              try await store.highestAccepted(channel: "stable") == nil else {
            fatalError("Rejected envelopes changed rollback history")
        }
        print("PASS: negative cases preserved isolated rollback state")
        print("SUCCESS: actual Swift production-key interoperability rehearsal passed")
    }
}

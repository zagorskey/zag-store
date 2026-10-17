import Foundation
import CryptoKit

/// Standalone compatibility verifier for the **public test key only**.
/// This verifier is NOT connected to Zag Store's live update path.
enum ZagMetadataV2TestVerifier {
    enum Failure: Error {
        case malformedEnvelope, badKey, badSignature, wrongChannel
        case invalidPayload, expired, replay
    }

    private static let signingPrefix = Data("ZAG-STORE-UPDATE-V2\n".utf8)
    private static let publicTestKeyId = "zag-v2-test-only"

    private struct Envelope: Decodable {
        let schema: Int
        let keyId: String
        let payload: String
        let signature: String
    }

    private struct Payload: Decodable {
        let schema: Int
        let appId: String
        let channel: String
        let sequence: Int
        let version: String
        let build: String
        let minimumIOSVersion: String
        let ipaURL: String
        let sha256: String
        let releaseNotes: String
        let publishedAt: String
        let expiresAt: String
    }

    /// Reject replayed sequence numbers without mutating persistent device state.
    /// Production must atomically persist sequence and payload digest.
    static func enforceSequence(
        sequence: Int,
        payloadDigest: Data,
        highestSequence: Int?,
        lastDigest: Data?
    ) throws {
        guard sequence > 0 else { throw Failure.invalidPayload }
        guard let highestSequence else { return }
        if sequence < highestSequence { throw Failure.replay }
        if sequence == highestSequence {
            guard let lastDigest, lastDigest == payloadDigest else { throw Failure.replay }
        }
    }

    /// Call only in an offline test harness; production must use a separately
    /// provisioned public-key trust store, strict JSON schema and rollback guard.
    static func verify(
        envelopeJSON: Data,
        testPublicKeyBase64: String,
        expectedChannel: String,
        now: Date
    ) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: envelopeJSON)
        guard envelope.schema == 2,
              envelope.keyId == publicTestKeyId,
              let payloadBytes = Data(base64Encoded: envelope.payload),
              let signatureBytes = Data(base64Encoded: envelope.signature),
              signatureBytes.count == 64 else { throw Failure.malformedEnvelope }
        guard let keyBytes = Data(base64Encoded: testPublicKeyBase64),
              keyBytes.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { throw Failure.badKey }
        var signedBytes = signingPrefix
        signedBytes.append(payloadBytes)
        guard key.isValidSignature(signatureBytes, for: signedBytes) else {
            throw Failure.badSignature
        }
        // Enforce exact field sets and JSON types. Codable alone ignores unknown keys.
        let requiredEnvelope = Set(["schema", "keyId", "payload", "signature"])
        let requiredPayload = Set([
            "schema", "appId", "channel", "sequence", "version", "build",
            "minimumIOSVersion", "ipaURL", "sha256", "releaseNotes",
            "publishedAt", "expiresAt"
        ])
        guard let envelopeObject = try JSONSerialization.jsonObject(with: envelopeJSON) as? [String: Any],
              Set(envelopeObject.keys) == requiredEnvelope,
              let object = try JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any],
              Set(object.keys) == requiredPayload
        else { throw Failure.invalidPayload }
        let payload = try JSONDecoder().decode(Payload.self, from: payloadBytes)
        guard payload.schema == 2,
              payload.appId == "com.cwd43.gu29",
              payload.channel == expectedChannel,
              payload.sequence > 0,
              !payload.version.isEmpty,
              !payload.build.isEmpty,
              !payload.minimumIOSVersion.isEmpty,
              payload.ipaURL.hasPrefix("https://github.com/zagorskey/zag-store-releases/releases/download/"),
              payload.sha256.utf8.count == 64,
              payload.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidPayload }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let published = formatter.date(from: payload.publishedAt),
              let expires = formatter.date(from: payload.expiresAt),
              expires > published,
              expires.timeIntervalSince(published) <= 7 * 24 * 60 * 60,
              now < expires else { throw Failure.expired }
    }
}

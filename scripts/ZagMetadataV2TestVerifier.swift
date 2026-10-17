import Foundation
import CryptoKit

/// Standalone compatibility verifier for the **public test key only**.
/// This verifier is NOT connected to Zag Store's live update path.
enum ZagMetadataV2TestVerifier {
    enum Failure: Error {
        case malformedEnvelope, badKey, badSignature, wrongChannel
        case invalidPayload, expired
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
        let payload = try JSONDecoder().decode(Payload.self, from: payloadBytes)
        guard payload.schema == 2,
              payload.appId == "com.cwd43.gu29",
              payload.channel == expectedChannel,
              payload.sequence > 0,
              !payload.version.isEmpty,
              !payload.build.isEmpty,
              !payload.minimumIOSVersion.isEmpty,
              payload.ipaURL.hasPrefix("https://github.com/zagorskey/zag-store-releases/releases/download/"),
              payload.sha256.count == 64 else { throw Failure.invalidPayload }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let published = formatter.date(from: payload.publishedAt),
              let expires = formatter.date(from: payload.expiresAt),
              expires > published,
              expires.timeIntervalSince(published) <= 7 * 24 * 60 * 60,
              now < expires else { throw Failure.expired }
    }
}

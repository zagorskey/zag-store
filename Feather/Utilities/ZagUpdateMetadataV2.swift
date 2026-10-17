import Foundation
import CryptoKit

/// Staged v2 validator shared by the app and host-side security tests.
/// Not yet connected to the production update discovery pipeline.
    /// V2 envelope checks are staged independently of the live v1 updater.
    /// No trust anchor is supplied until the production release key is provisioned.
    enum V2Metadata {
        static let domain = Data("ZAG-STORE-UPDATE-V2\n".utf8)

        struct Envelope: Decodable {
            let schema: Int
            let keyId: String
            let payload: String
            let signature: String
        }

        enum ValidationError: Error {
            case invalidEnvelope, untrustedKey, invalidSignature, invalidPayload
        }

        static func verifiedPayload(_ data: Data, trustedKeys: [String: Data]) throws -> Data {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schema == 2,
                  let publicKeyData = trustedKeys[envelope.keyId],
                  publicKeyData.count == 32 else { throw ValidationError.untrustedKey }
            guard let payload = Data(base64Encoded: envelope.payload),
                  let signature = Data(base64Encoded: envelope.signature),
                  signature.count == 64,
                  payload.base64EncodedString() == envelope.payload,
                  signature.base64EncodedString() == envelope.signature else {
                throw ValidationError.invalidEnvelope
            }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard publicKey.isValidSignature(signature, for: domain + payload) else {
                throw ValidationError.invalidSignature
            }
            return payload
        }

        struct Payload: Decodable {
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

        static func validatePayload(_ bytes: Data, channel: String, now: Date = Date()) throws -> Payload {
            // Fail closed on non-ASCII payloads until a full RFC 8785 canonicalizer
            // is available. Our current publisher's ASCII fixtures use the same
            // sorted-key compact encoding as Foundation's serializer.
            // Byte equality also rejects duplicate keys (including escaped-key
            // aliases), noncanonical whitespace and alternate numeric encodings.
            guard bytes.allSatisfy({ $0 < 128 }),
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  JSONSerialization.isValidJSONObject(object),
                  let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                  canonical == bytes,
                  Set(object.keys) == Set([
                    "schema", "appId", "channel", "sequence", "version", "build",
                    "minimumIOSVersion", "ipaURL", "sha256", "releaseNotes", "publishedAt", "expiresAt"
                  ]) else { throw ValidationError.invalidPayload }
            let payload = try JSONDecoder().decode(Payload.self, from: bytes)
            guard payload.schema == 2,
                  payload.appId == "app.zagstore.ios",
                  payload.channel == channel,
                  ["stable", "beta", "nightly"].contains(channel),
                  payload.sequence > 0,
                  !payload.version.isEmpty,
                  payload.version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isNumber }) }),
                  !payload.build.isEmpty && payload.build.allSatisfy({ $0.isNumber }),
                  !payload.minimumIOSVersion.isEmpty,
                  !payload.releaseNotes.isEmpty,
                  let url = URL(string: payload.ipaURL),
                  url.scheme == "https",
                  url.host == "github.com",
                  url.path.hasPrefix("/zagorskey/zag-store-releases/releases/download/"),
                  payload.sha256.count == 64,
                  payload.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ValidationError.invalidPayload
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let published = formatter.date(from: payload.publishedAt),
                  let expires = formatter.date(from: payload.expiresAt),
                  payload.publishedAt.hasSuffix("Z"), payload.expiresAt.hasSuffix("Z"),
                  published < expires,
                  expires.timeIntervalSince(published) <= 7 * 24 * 3600,
                  published <= now, now < expires else {
                throw ValidationError.invalidPayload
            }
            return payload
        }
    }


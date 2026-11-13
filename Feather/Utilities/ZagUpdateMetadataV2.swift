import Foundation
import CryptoKit

/// Staged v2 validator shared by the app and host-side security tests.
/// Not yet connected to the production update discovery pipeline.
    /// V2 envelope checks are staged independently of the live v1 updater.
    /// No trust anchor is supplied until the production release key is provisioned.
enum ZagUpdateMetadataV2 {
        static let domain = Data("ZAG-STORE-UPDATE-V2\n".utf8)

        struct Envelope: Decodable {
            let schema: Int
            let keyId: String
            let payload: String
            let signature: String
        }

        // Append new cases only: shipped builds report these by position
        // ("ValidationError error 3" is invalidPayload).
        enum ValidationError: Error, LocalizedError {
            case invalidEnvelope, untrustedKey, invalidSignature, invalidPayload
            case expired, notYetValid

            var errorDescription: String? {
                switch self {
                case .invalidEnvelope:
                    return "The update information is malformed."
                case .untrustedKey:
                    return "The update information is signed with a key this version of Zag Store doesn't trust."
                case .invalidSignature:
                    return "The update information's signature is invalid."
                case .invalidPayload:
                    return "The update information doesn't match this app or channel."
                case .expired:
                    return "The published update information has expired. Zag Store will find updates again once it is renewed."
                case .notYetValid:
                    return "The update information isn't valid yet. Check that this device's date and time are correct."
                }
            }
        }

        static func verifiedPayload(_ data: Data, trustedKeys: [String: Data]) throws -> Data {
            // Limit untrusted input before parsing or allocating decoded payloads.
            guard data.count <= 256 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["schema", "keyId", "payload", "signature"]),
                  object["schema"] is NSNumber,
                  let keyId = object["keyId"] as? String,
                  !keyId.isEmpty, keyId.utf8.count <= 64,
                  let encodedPayload = object["payload"] as? String,
                  encodedPayload.utf8.count <= 192 * 1024,
                  let encodedSignature = object["signature"] as? String,
                  encodedSignature.utf8.count <= 128 else {
                throw ValidationError.invalidEnvelope
            }
            // Strict byte-level envelope canonicality rejects duplicate keys,
            // escaped-key aliases and ambiguous spellings before JSONDecoder.
            guard data.allSatisfy({ $0 < 128 }),
                  let canonical = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.sortedKeys, .withoutEscapingSlashes]
                  ), canonical == data else {
                throw ValidationError.invalidEnvelope
            }
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
            // Schema-constrained canonical JSON: payloads contain only strings
            // and the two integer fields (schema, sequence), never floats.
            // Compare exact bytes to reject duplicate keys, escaped-key aliases,
            // whitespace and alternate encodings. This is not general RFC 8785.
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  JSONSerialization.isValidJSONObject(object),
                  let schemaNumber = object["schema"] as? NSNumber,
                  let sequenceNumber = object["sequence"] as? NSNumber,
                  CFGetTypeID(schemaNumber) != CFBooleanGetTypeID(),
                  CFGetTypeID(sequenceNumber) != CFBooleanGetTypeID(),
                  String(cString: schemaNumber.objCType) != "d",
                  String(cString: schemaNumber.objCType) != "f",
                  String(cString: sequenceNumber.objCType) != "d",
                  String(cString: sequenceNumber.objCType) != "f",
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
                  expires.timeIntervalSince(published) <= 7 * 24 * 3600 else {
                throw ValidationError.invalidPayload
            }
            // Same window as before, reported separately so an unrenewed
            // manifest isn't shown as corrupt.
            guard published <= now else { throw ValidationError.notYetValid }
            guard now < expires else { throw ValidationError.expired }
            return payload
        }
    }


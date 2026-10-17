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

    /// Byte-level validation of the currently specified flat v2 payload schema.
    /// No nested values, escaped key names, number exponents or extra JSON
    /// whitespace are needed by this protocol. Exact JCS spelling is checked
    /// by serializing the parsed primitive values with sorted keys below.
    private static func isCanonicalFlatPayload(_ bytes: Data) -> Bool {
        guard let string = String(data: bytes, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object.count == 12 else { return false }
        // Foundation's dictionary parser can lose duplicate members. Recover
        // key occurrences directly from the raw JSON token stream with a
        // small lexical scanner; treat backslash escapes conservatively.
        let chars = Array(string.utf8)
        var i = 0
        func skipSpace() {
            while i < chars.count && (chars[i] == 32 || chars[i] == 9 || chars[i] == 10 || chars[i] == 13) { i += 1 }
        }
        func quoted() -> String? {
            guard i < chars.count && chars[i] == 34 else { return nil }
            let start = i
            i += 1
            while i < chars.count {
                if chars[i] == 92 {
                    i += 2
                    continue
                }
                if chars[i] == 34 {
                    i += 1
                    let slice = Data(chars[start..<i])
                    guard let decoded = try? JSONSerialization.jsonObject(
                        with: Data("[\(String(data: slice, encoding: .utf8) ?? "")]".utf8)
                    ) as? [String] else { return nil }
                    return decoded.first
                }
                i += 1
            }
            return nil
        }
        skipSpace()
        guard i < chars.count && chars[i] == 123 else { return false }
        i += 1
        var names = Set<String>()
        while true {
            skipSpace()
            guard let name = quoted(), names.insert(name).inserted else { return false }
            skipSpace()
            guard i < chars.count && chars[i] == 58 else { return false }
            i += 1
            skipSpace()
            if i < chars.count && chars[i] == 34 {
                guard quoted() != nil else { return false }
            } else {
                let start = i
                while i < chars.count && chars[i] != 44 && chars[i] != 125 { i += 1 }
                let value = String(decoding: chars[start..<i], as: UTF8.self)
                guard !value.isEmpty, value.allSatisfy({ $0.isNumber || $0 == "-" }) else { return false }
            }
            skipSpace()
            guard i < chars.count else { return false }
            if chars[i] == 125 {
                i += 1
                break
            }
            guard chars[i] == 44 else { return false }
            i += 1
        }
        skipSpace()
        guard i == chars.count, names.count == object.count else { return false }

        // JCS's lexical order for these ASCII field names matches sortedKeys.
        // Only strings and positive integral numbers are legal in v2 metadata.
        guard JSONSerialization.isValidJSONObject(object),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return false }
        return canonical == bytes
    }

    private static func numericDotted(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private static func numericBuild(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func trustedIPAURL(_ string: String) -> Bool {
        guard let components = URLComponents(string: string),
              components.scheme == "https",
              components.host == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              !components.percentEncodedPath.lowercased().contains("%2f"),
              !components.percentEncodedPath.lowercased().contains("%5c"),
              components.path.hasPrefix("/zagorskey/zag-store-releases/releases/download/"),
              let url = components.url,
              url.absoluteString == string else { return false }
        return true
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
        // The v2 payload schema contains only flat, primitive JSON values.
        // Scan bytes for a single unambiguous canonical representation before
        // trusting Foundation's dictionaries (which discard duplicate keys).
        guard isCanonicalFlatPayload(payloadBytes) else { throw Failure.invalidPayload }
        let payload = try JSONDecoder().decode(Payload.self, from: payloadBytes)
        guard payload.schema == 2,
              payload.appId == "com.cwd43.gu29",
              payload.channel == expectedChannel,
              payload.sequence > 0,
              numericDotted(payload.version),
              numericBuild(payload.build),
              numericDotted(payload.minimumIOSVersion),
              trustedIPAURL(payload.ipaURL),
              payload.sha256.utf8.count == 64,
              payload.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidPayload }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let published = formatter.date(from: payload.publishedAt),
              let expires = formatter.date(from: payload.expiresAt),
              expires > published,
              expires.timeIntervalSince(published) <= 7 * 24 * 60 * 60,
              published <= now,
              now < expires else { throw Failure.expired }
    }
}

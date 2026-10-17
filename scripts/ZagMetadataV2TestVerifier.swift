import Foundation
import CryptoKit

/// Standalone compatibility verifier using an explicitly pinned public-key registry.
/// This verifier is NOT connected to Zag Store's live update path.
enum ZagMetadataV2TestVerifier {
    enum Failure: Error {
        case malformedEnvelope, badKey, badSignature, wrongChannel
        case invalidPayload, expired, replay
    }

    private static let signingPrefix = Data("ZAG-STORE-UPDATE-V2\n".utf8)

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

    /// Require literal, unique envelope keys with unambiguous string values.
    /// This deliberately accepts ordinary envelope whitespace and key ordering,
    /// but rejects duplicate keys, escaped key names and nested values.
    private static func isStrictEnvelope(_ bytes: Data) -> Bool {
        let input = Array(bytes)
        var index = 0
        func space() {
            while index < input.count && [9, 10, 13, 32].contains(input[index]) {
                index += 1
            }
        }
        func take(_ value: UInt8) -> Bool {
            space()
            guard index < input.count, input[index] == value else { return false }
            index += 1
            return true
        }
        func string() -> String? {
            guard take(34) else { return nil }
            let start = index
            while index < input.count {
                if input[index] == 92 { return nil } // No escape sequences in envelope.
                if input[index] == 34 {
                    let part = input[start..<index]
                    index += 1
                    guard part.allSatisfy({ $0 >= 32 }) else { return nil }
                    return String(bytes: part, encoding: .utf8)
                }
                index += 1
            }
            return nil
        }
        guard take(123) else { return false }
        var names = Set<String>()
        while true {
            guard let name = string(), names.insert(name).inserted,
                  take(58) else { return false }
            if name == "schema" {
                space()
                guard index < input.count, input[index] == 50 else { return false }
                index += 1
            } else if ["keyId", "payload", "signature"].contains(name) {
                guard string() != nil else { return false }
            } else {
                return false
            }
            space()
            if take(125) { break }
            guard take(44) else { return false }
        }
        space()
        return index == input.count &&
            names == Set(["schema", "keyId", "payload", "signature"])
    }

    /// Canonical RFC 4648 base64 only: no ignored bytes, extra padding or
    /// alternate spellings of signed payload/signature fields.
    private static func strictBase64(_ text: String) -> Data? {
        guard let decoded = Data(base64Encoded: text),
              decoded.base64EncodedString() == text else { return nil }
        return decoded
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
              !components.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              components.path.hasPrefix("/zagorskey/zag-store-releases/releases/download/"),
              components.path.dropFirst("/zagorskey/zag-store-releases/releases/download/".count)
                  .split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              components.path.dropFirst("/zagorskey/zag-store-releases/releases/download/".count)
                  .split(separator: "/", omittingEmptySubsequences: false).count == 2,
              components.path.hasSuffix(".ipa"),
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

    /// Offline verification with an immutable registry provided by the caller.
    /// Not integrated with the production updater or persistent rollback state.
    static func verify(
        envelopeJSON: Data,
        trustedKeys: ZagMetadataV2KeyRegistry,
        expectedChannel: String,
        now: Date
    ) throws {
        guard isStrictEnvelope(envelopeJSON) else { throw Failure.malformedEnvelope }
        let envelope = try JSONDecoder().decode(Envelope.self, from: envelopeJSON)
        guard envelope.schema == 2,
              let payloadBytes = strictBase64(envelope.payload),
              let signatureBytes = strictBase64(envelope.signature),
              signatureBytes.count == 64 else { throw Failure.malformedEnvelope }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try trustedKeys.publicKey(for: envelope.keyId)
        } catch {
            throw Failure.badKey
        }
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

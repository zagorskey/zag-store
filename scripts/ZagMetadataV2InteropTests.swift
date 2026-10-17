import Foundation

@main
struct ZagMetadataV2InteropTests {
    struct Fixture: Decodable {
        let publicKeyBase64: String
        let envelope: Envelope
        let signedNegativeCases: [String: Envelope]
        let signedPositiveCases: [String: Envelope]
    }
    struct Envelope: Codable {
        let schema: Int
        let keyId: String
        let payload: String
        let signature: String
    }

    static func requireReject(_ name: String, _ run: () throws -> Void) throws {
        do {
            try run()
            throw TestFailure.accepted(name)
        } catch let error as TestFailure {
            throw error
        } catch {
            print("PASS: \(name) rejected")
        }
    }

    enum TestFailure: Error {
        case accepted(String)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: ZagMetadataV2InteropTests /path/to/vector.json\n", stderr)
            exit(2)
        }
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureData)
        let now = ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z")!
        let trustedKeys = try ZagMetadataV2KeyRegistry(anchors: [
            .init(keyID: fixture.envelope.keyId, publicKeyBase64: fixture.publicKeyBase64)
        ])
        func encode(_ envelope: Envelope) throws -> Data {
            try JSONEncoder().encode(envelope)
        }
        let original = try encode(fixture.envelope)
        try ZagMetadataV2TestVerifier.verify(
            envelopeJSON: original,
            trustedKeys: trustedKeys,
            expectedChannel: "beta",
            now: now)
        print("PASS: Swift verified Python-signed Ed25519 payload")
        for name in fixture.signedPositiveCases.keys.sorted() {
            guard let candidate = fixture.signedPositiveCases[name] else {
                throw TestFailure.accepted("Missing positive case: \(name)")
            }
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: try encode(candidate),
                trustedKeys: trustedKeys,
                expectedChannel: "beta",
                now: now)
            print("PASS: Canonical signed positive payload: \(name)")
        }

        try requireReject("Wrong channel") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: original,
                trustedKeys: trustedKeys,
                expectedChannel: "stable",
                now: now)
        }
        let expired = ISO8601DateFormatter().date(from: "2026-10-21T00:00:00Z")!
        try requireReject("Expired metadata") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: original,
                trustedKeys: trustedKeys,
                expectedChannel: "beta",
                now: expired)
        }
        guard var signatureData = Data(base64Encoded: fixture.envelope.signature) else {
            throw TestFailure.accepted("Invalid fixture signature")
        }
        signatureData[0] ^= 1
        var altered = fixture.envelope
        altered = Envelope(schema: altered.schema, keyId: altered.keyId,
                           payload: altered.payload,
                           signature: signatureData.base64EncodedString())
        let tampered = try encode(altered)
        try requireReject("Tampered signature") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: tampered,
                trustedKeys: trustedKeys,
                expectedChannel: "beta",
                now: now)
        }
        let unknownTrust = try ZagMetadataV2KeyRegistry(anchors: [])
        try requireReject("Untrusted signing key ID") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: original,
                trustedKeys: unknownTrust,
                expectedChannel: "beta",
                now: now)
        }
        // Verify envelope schema enforcement with the existing signed fixture.
        let extraEnvelope = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var injectedEnvelope = extraEnvelope
        injectedEnvelope["unexpected"] = "must reject"
        let extraEnvelopeData = try JSONSerialization.data(withJSONObject: injectedEnvelope)
        try requireReject("Unknown envelope field") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: extraEnvelopeData,
                trustedKeys: trustedKeys,
                expectedChannel: "beta",
                now: now)
        }
        var missingEnvelope = extraEnvelope
        missingEnvelope.removeValue(forKey: "keyId")
        let missingEnvelopeData = try JSONSerialization.data(withJSONObject: missingEnvelope)
        try requireReject("Missing envelope field") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: missingEnvelopeData,
                trustedKeys: trustedKeys,
                expectedChannel: "beta",
                now: now)
        }
        // Signed payload field-set rejection requires a newly signed invalid
        // payload fixture; do not mistake tampering (signature failure) for
        // an actual schema-validation test.
        for name in fixture.signedNegativeCases.keys.sorted() {
            guard let invalidEnvelope = fixture.signedNegativeCases[name] else {
                fatalError("FAIL: Missing negative case \(name)")
            }
            let candidate = try encode(invalidEnvelope)
            try requireReject("Valid-signature malformed payload: \(name)") {
                try ZagMetadataV2TestVerifier.verify(
                    envelopeJSON: candidate,
                    trustedKeys: trustedKeys,
                    expectedChannel: "beta",
                    now: now)
            }
        }
        let digest = Data(repeating: 0x42, count: 32)
        try ZagMetadataV2TestVerifier.enforceSequence(
            sequence: 7, payloadDigest: digest, highestSequence: 7, lastDigest: digest)
        print("PASS: Identical sequence and payload accepted")
        try ZagMetadataV2TestVerifier.enforceSequence(
            sequence: 8, payloadDigest: digest, highestSequence: 7, lastDigest: digest)
        print("PASS: Higher sequence accepted")
        try requireReject("Lower sequence replay") {
            try ZagMetadataV2TestVerifier.enforceSequence(
                sequence: 6, payloadDigest: digest, highestSequence: 7, lastDigest: digest)
        }
        try requireReject("Conflicting equal sequence") {
            try ZagMetadataV2TestVerifier.enforceSequence(
                sequence: 7, payloadDigest: Data(repeating: 0x24, count: 32),
                highestSequence: 7, lastDigest: digest)
        }
        print("SUCCESS: Python-to-Swift signing interoperability and replay tests passed")
    }
}

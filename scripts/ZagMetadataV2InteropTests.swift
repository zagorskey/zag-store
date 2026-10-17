import Foundation

@main
struct ZagMetadataV2InteropTests {
    struct Fixture: Decodable {
        let publicKeyBase64: String
        let envelope: Envelope
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
        func encode(_ envelope: Envelope) throws -> Data {
            try JSONEncoder().encode(envelope)
        }
        let original = try encode(fixture.envelope)
        try ZagMetadataV2TestVerifier.verify(
            envelopeJSON: original,
            testPublicKeyBase64: fixture.publicKeyBase64,
            expectedChannel: "beta",
            now: now)
        print("PASS: Swift verified Python-signed Ed25519 payload")

        try requireReject("Wrong channel") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: original,
                testPublicKeyBase64: fixture.publicKeyBase64,
                expectedChannel: "stable",
                now: now)
        }
        let expired = ISO8601DateFormatter().date(from: "2026-10-21T00:00:00Z")!
        try requireReject("Expired metadata") {
            try ZagMetadataV2TestVerifier.verify(
                envelopeJSON: original,
                testPublicKeyBase64: fixture.publicKeyBase64,
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
                testPublicKeyBase64: fixture.publicKeyBase64,
                expectedChannel: "beta",
                now: now)
        }
        print("SUCCESS: Python-to-Swift signing interoperability tests passed")
    }
}

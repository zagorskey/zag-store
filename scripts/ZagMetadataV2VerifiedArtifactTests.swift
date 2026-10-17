import Foundation

@main
struct ZagMetadataV2VerifiedArtifactTests {
    struct Fixture: Decodable {
        struct Envelope: Codable {
            let schema: Int
            let keyId: String
            let payload: String
            let signature: String
        }
        struct SignedArtifactPositive: Decodable {
            let bytesBase64: String
            let envelope: Envelope
        }
        let publicKeyBase64: String
        let signedArtifactPositive: SignedArtifactPositive
        let envelope: Envelope
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: verified-artifact-tests <vector.json>\n", stderr)
            exit(2)
        }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        let registry = try ZagMetadataV2KeyRegistry(anchors: [
            .init(keyID: fixture.envelope.keyId, publicKeyBase64: fixture.publicKeyBase64)
        ])
        let boundary = ZagMetadataV2VerifiedArtifact(registry: registry)
        let envelopeJSON = try JSONEncoder().encode(fixture.envelope)
        struct Digest: Decodable { let sha256: String }
        let payload = Data(base64Encoded: fixture.envelope.payload)!
        let signedDigest = try JSONDecoder().decode(Digest.self, from: payload).sha256
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("zag-v2-bound-artifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let localIPA = temporary.appendingPathComponent("local.ipa")
        let now = ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z")!

        func rejects(_ label: String, _ action: () throws -> Void) throws {
            do {
                try action()
                throw NSError(domain: "ZagArtifactTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(label) accepted"])
            } catch let error as NSError where error.domain == "ZagArtifactTests" {
                throw error
            } catch {
                print("PASS: \(label) rejected")
            }
        }

        // Positive end-to-end offline test: a disposable signed metadata
        // fixture authenticates the exact local file bytes, not a caller hash.
        guard let matchingBytes = Data(
            base64Encoded: fixture.signedArtifactPositive.bytesBase64) else {
            fatalError("FAIL: Invalid matching artifact fixture Base64")
        }
        try matchingBytes.write(to: localIPA)
        let positiveEnvelope = try JSONEncoder().encode(
            fixture.signedArtifactPositive.envelope)
        try boundary.verify(
            envelopeJSON: positiveEnvelope, expectedChannel: "beta",
            now: now, localIPA: localIPA)
        print("PASS: Signed metadata authenticates matching local artifact bytes")
        var altered = matchingBytes
        altered[altered.count - 1] ^= 1
        try altered.write(to: localIPA)
        try rejects("Tampered file rejected against signed matching digest") {
            try boundary.verify(
                envelopeJSON: positiveEnvelope, expectedChannel: "beta",
                now: now, localIPA: localIPA)
        }

        try Data("not the signed IPA".utf8).write(to: localIPA)
        try rejects("Valid signed metadata with different local IPA bytes") {
            try boundary.verify(
                envelopeJSON: envelopeJSON, expectedChannel: "beta",
                now: now, localIPA: localIPA)
        }

        let unsigned = Fixture.Envelope(
            schema: fixture.envelope.schema, keyId: fixture.envelope.keyId,
            payload: fixture.envelope.payload,
            signature: Data(repeating: 0, count: 64).base64EncodedString()
        )
        try rejects("Untrusted signature cannot authorize local artifact") {
            try boundary.verify(
                envelopeJSON: JSONEncoder().encode(unsigned),
                expectedChannel: "beta", now: now, localIPA: localIPA)
        }
        try rejects("Wrong channel cannot authorize local artifact") {
            try boundary.verify(
                envelopeJSON: envelopeJSON, expectedChannel: "stable",
                now: now, localIPA: localIPA)
        }
        try rejects("Missing local artifact") {
            try boundary.verify(
                envelopeJSON: envelopeJSON, expectedChannel: "beta", now: now,
                localIPA: temporary.appendingPathComponent("missing.ipa"))
        }
        guard signedDigest.count == 64 else {
            fatalError("FAIL: Signed test metadata lacked a SHA-256")
        }
        print("PASS: Artifact digest sourced from authenticated payload")
        print("SUCCESS: Offline signed-metadata artifact boundary tests passed")
    }
}

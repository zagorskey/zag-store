import Foundation

@main
struct ZagMetadataV2VerifiedSequenceTests {
    struct Fixture: Decodable {
        struct Envelope: Codable {
            let schema: Int
            let keyId: String
            let payload: String
            let signature: String
        }
        let publicKeyBase64: String
        let envelope: Envelope
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: verified-sequence-tests <vector.json>\n", stderr)
            exit(2)
        }
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let registry = try ZagMetadataV2KeyRegistry(anchors: [
            .init(keyID: fixture.envelope.keyId, publicKeyBase64: fixture.publicKeyBase64)
        ])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zag-v2-verified-sequence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sequence.json")
        let now = ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z")!
        let boundary = ZagMetadataV2VerifiedSequence(
            registry: registry,
            store: ZagMetadataV2SequenceStore(fileURL: url))
        let original = try JSONEncoder().encode(fixture.envelope)
        try boundary.verifyAndRecord(envelopeJSON: original, expectedChannel: "beta", now: now)
        guard try boundary.store.read(channel: "beta")?.sequence == 7 else {
            fatalError("FAIL: Verified sequence was not persisted")
        }
        print("PASS: Valid signed metadata persisted sequence 7")
        func mustReject(_ label: String, _ operation: () throws -> Void) throws {
            do {
                try operation()
            } catch {
                print("PASS: \(label) rejected")
                return
            }
            throw NSError(domain: "ZagV2Test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(label) accepted"])
        }
        var tamperedSignature = Data(base64Encoded: fixture.envelope.signature)!
        tamperedSignature[0] ^= 1
        let tampered = Fixture.Envelope(
            schema: fixture.envelope.schema, keyId: fixture.envelope.keyId,
            payload: fixture.envelope.payload,
            signature: tamperedSignature.base64EncodedString())
        try mustReject("Tampered signed metadata") {
            try boundary.verifyAndRecord(
                envelopeJSON: try JSONEncoder().encode(tampered),
                expectedChannel: "beta", now: now)
        }
        try mustReject("Wrong channel metadata") {
            try boundary.verifyAndRecord(
                envelopeJSON: original, expectedChannel: "stable", now: now)
        }
        try mustReject("Expired signed metadata") {
            try boundary.verifyAndRecord(
                envelopeJSON: original, expectedChannel: "beta",
                now: ISO8601DateFormatter().date(from: "2026-10-21T00:00:00Z")!)
        }
        guard try boundary.store.read(channel: "beta")?.sequence == 7,
              try boundary.store.read(channel: "stable") == nil else {
            fatalError("FAIL: Rejected metadata modified persistent sequence state")
        }
        print("PASS: Rejected metadata left trusted sequence state unchanged")
        let restarted = ZagMetadataV2SequenceStore(fileURL: url)
        guard try restarted.read(channel: "beta")?.sequence == 7 else {
            fatalError("FAIL: Verified sequence not preserved across restart")
        }
        print("PASS: Verified sequence survives process-level store restart")
        let restartedBoundary = ZagMetadataV2VerifiedSequence(
            registry: registry, store: restarted)
        try restartedBoundary.verifyAndRecord(
            envelopeJSON: original, expectedChannel: "beta", now: now)
        print("PASS: Identical verified payload accepted after restart")
        let alternatePayload = Data("different verified payload bytes".utf8)
        try restarted.accept(channel: "beta", sequence: 8, signedPayload: alternatePayload)
        try mustReject("Replayed signed sequence after restart") {
            try restartedBoundary.verifyAndRecord(
                envelopeJSON: original, expectedChannel: "beta", now: now)
        }
        guard try restarted.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Rejected replay changed persisted high-water mark")
        }
        print("PASS: Replayed verified payload preserved high-water mark")

        // Equal sequence with different bytes must be rejected without changing
        // the trusted digest or high-water mark, including after store restart.
        let beforeConflict = try restarted.read(channel: "beta")
        try mustReject("Conflicting payload at an accepted sequence") {
            try restarted.accept(
                channel: "beta", sequence: 8,
                signedPayload: Data("conflicting sequence-eight bytes".utf8))
        }
        guard try restarted.read(channel: "beta") == beforeConflict else {
            fatalError("FAIL: Sequence conflict modified trusted state")
        }
        print("PASS: Conflicting equal-sequence payload preserved trusted state")

        print("SUCCESS: Offline verified-metadata persistence integration tests passed")
    }
}

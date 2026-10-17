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
        let signedEqualSequenceConflict: Envelope
        let signedHigherSequence: Envelope
        let rotatedPublicKeyBase64: String
        let signedRotatedKeyUpgrade: Envelope
        let signedNegativeCases: [String: Envelope]
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

        // Even when the renamed signed snapshot is visible, a failed
        // directory fsync must not be reported as durable acceptance.
        let uncertaintyURL = dir.appendingPathComponent("uncertain-signed-state.json")
        var uncertainStore = ZagMetadataV2SequenceStore(fileURL: uncertaintyURL)
        uncertainStore.afterRenameForTesting = {
            throw ZagMetadataV2SequenceStore.StoreError.publicationUncertain
        }
        let uncertainBoundary = ZagMetadataV2VerifiedSequence(
            registry: registry, store: uncertainStore)
        do {
            try uncertainBoundary.verifyAndRecord(
                envelopeJSON: original, expectedChannel: "beta", now: now)
            fatalError("FAIL: Uncertain signed metadata was accepted as durable")
        } catch ZagMetadataV2SequenceStore.StoreError.publicationUncertain {
            print("PASS: Uncertain signed metadata never reported as durable acceptance")
        }
        let observedUncertain = try ZagMetadataV2SequenceStore(fileURL: uncertaintyURL)
            .read(channel: "beta")
        guard observedUncertain?.sequence == 7 else {
            fatalError("FAIL: Post-rename signed state not visible for reconciliation")
        }
        print("PASS: Uncertain signed publication re-read confirms visible high-water mark")
        // A fresh coordinator may safely retry exactly the same verified
        // manifest after the earlier publication reported uncertainty.
        let retryStore = ZagMetadataV2SequenceStore(fileURL: uncertaintyURL)
        let retryBoundary = ZagMetadataV2VerifiedSequence(
            registry: registry, store: retryStore)
        try retryBoundary.verifyAndRecord(
            envelopeJSON: original, expectedChannel: "beta", now: now)
        print("PASS: Identical signed manifest retries after uncertain publication")
        guard try retryStore.read(channel: "beta")?.sequence == 7 else {
            fatalError("FAIL: Identical retry lost the uncertain high-water mark")
        }
        print("PASS: Identical retry preserves high-water mark")

        let conflictEnvelope = try JSONEncoder().encode(fixture.signedEqualSequenceConflict)
        // A different validly signed manifest at the same sequence must not
        // replace state recovered after an uncertain publication.
        let recoveredBeforeConflict = try retryStore.read(channel: "beta")
        try mustReject("Conflicting signed manifest after uncertain publication") {
            try retryBoundary.verifyAndRecord(
                envelopeJSON: conflictEnvelope, expectedChannel: "beta", now: now)
        }
        guard try retryStore.read(channel: "beta") == recoveredBeforeConflict else {
            fatalError("FAIL: Conflicting retry changed recovered trusted state")
        }
        print("PASS: Conflicting retry preserves recovered high-water mark")
        // Reopen the state after uncertain publication and a conflicting
        // retry. Recovery must not re-admit a conflicting same-sequence
        // manifest, and an older signed sequence must remain a rollback.
        let recoveredAgain = ZagMetadataV2SequenceStore(fileURL: uncertaintyURL)
        let recoveredAgainBoundary = ZagMetadataV2VerifiedSequence(
            registry: registry, store: recoveredAgain)
        guard try recoveredAgain.read(channel: "beta") == recoveredBeforeConflict else {
            fatalError("FAIL: Recovered uncertain state changed across restart")
        }
        print("PASS: Uncertain-publication state survives coordinator restart")
        try mustReject("Conflicting signed retry after coordinator restart") {
            try recoveredAgainBoundary.verifyAndRecord(
                envelopeJSON: conflictEnvelope, expectedChannel: "beta", now: now)
        }
        guard try recoveredAgain.read(channel: "beta") == recoveredBeforeConflict else {
            fatalError("FAIL: Restarted conflict retry changed trusted digest")
        }
        print("PASS: Restarted conflicting retry preserves trusted digest")

        // Establish that the alternate envelope is independently valid before
        // asserting that persistent equal-sequence conflict protection rejects it.
        try ZagMetadataV2TestVerifier.verify(
            envelopeJSON: conflictEnvelope, trustedKeys: registry,
            expectedChannel: "beta", now: now)
        print("PASS: Alternate equal-sequence metadata has a valid signature")
        let stateBeforeSignedConflict = try boundary.store.read(channel: "beta")
        try mustReject("Independently signed equal-sequence conflict") {
            try boundary.verifyAndRecord(
                envelopeJSON: conflictEnvelope, expectedChannel: "beta", now: now)
        }
        guard try boundary.store.read(channel: "beta") == stateBeforeSignedConflict else {
            fatalError("FAIL: Signed equal-sequence conflict modified trusted state")
        }
        print("PASS: Signed equal-sequence conflict preserved trusted state")
        // Foundation can decode some alternate Base64 spellings. The verifier
        // must reject them before they reach trusted persistence.
        let beforeNoncanonicalBase64 = try boundary.store.read(channel: "beta")
        let paddedSignature = Fixture.Envelope(
            schema: fixture.envelope.schema, keyId: fixture.envelope.keyId,
            payload: fixture.envelope.payload,
            signature: fixture.envelope.signature + "=")
        try mustReject("Noncanonical signature Base64") {
            try boundary.verifyAndRecord(
                envelopeJSON: try JSONEncoder().encode(paddedSignature),
                expectedChannel: "beta", now: now)
        }
        let paddedPayload = Fixture.Envelope(
            schema: fixture.envelope.schema, keyId: fixture.envelope.keyId,
            payload: fixture.envelope.payload + "=",
            signature: fixture.envelope.signature)
        try mustReject("Noncanonical payload Base64") {
            try boundary.verifyAndRecord(
                envelopeJSON: try JSONEncoder().encode(paddedPayload),
                expectedChannel: "beta", now: now)
        }
        guard try boundary.store.read(channel: "beta") == beforeNoncanonicalBase64 else {
            fatalError("FAIL: Noncanonical Base64 changed trusted sequence state")
        }
        print("PASS: Noncanonical Base64 rejection preserved trusted state")
        // Construct raw JSON rather than using JSONEncoder, which cannot
        // represent duplicate keys. A valid signature must not excuse an
        // ambiguous envelope or an escaped field name.
        let beforeMalformedEnvelope = try boundary.store.read(channel: "beta")
        let originalJSON = String(decoding: original, as: UTF8.self)
        guard originalJSON.hasPrefix("{") else {
            fatalError("FAIL: Test fixture is not a JSON object")
        }
        let duplicateKeyJSON = Data(
            ("{\"schema\":2," + originalJSON.dropFirst()).utf8)
        try mustReject("Duplicate envelope schema key") {
            try boundary.verifyAndRecord(
                envelopeJSON: duplicateKeyJSON, expectedChannel: "beta", now: now)
        }
        guard let payloadKey = originalJSON.range(of: "\"payload\"") else {
            fatalError("FAIL: Payload field not found in test envelope")
        }
        var escapedKeyJSON = originalJSON
        escapedKeyJSON.replaceSubrange(payloadKey, with: "\"pay\\u006coad\"")
        try mustReject("Escaped envelope field name") {
            try boundary.verifyAndRecord(
                envelopeJSON: Data(escapedKeyJSON.utf8),
                expectedChannel: "beta", now: now)
        }
        guard try boundary.store.read(channel: "beta") == beforeMalformedEnvelope else {
            fatalError("FAIL: Malformed envelopes changed trusted sequence state")
        }
        print("PASS: Malformed envelope rejection preserved trusted state")

        // Structurally invalid envelopes must be rejected before their contents
        // can influence persistent rollback state.
        let beforeInvalidEnvelopeShape = try boundary.store.read(channel: "beta")
        guard let schemaField = originalJSON.range(of: #""schema":2"#) else {
            fatalError("FAIL: Schema field not found in test envelope")
        }
        var stringSchemaJSON = originalJSON
        stringSchemaJSON.replaceSubrange(schemaField, with: #""schema":"2""#)
        try mustReject("String-valued envelope schema") {
            try boundary.verifyAndRecord(
                envelopeJSON: Data(stringSchemaJSON.utf8),
                expectedChannel: "beta", now: now)
        }

        let unexpectedFieldJSON = Data(
            (#"{"unexpected":true,"# + originalJSON.dropFirst()).utf8)
        try mustReject("Unexpected envelope field") {
            try boundary.verifyAndRecord(
                envelopeJSON: unexpectedFieldJSON,
                expectedChannel: "beta", now: now)
        }
        guard try boundary.store.read(channel: "beta") == beforeInvalidEnvelopeShape else {
            fatalError("FAIL: Invalid envelope shape modified trusted state")
        }
        print("PASS: Invalid envelope shape preserved trusted state")
        // These malformed payloads carry real test-key signatures. The
        // verifier must reject their contents, not merely bad signatures.
        let beforeMalformedSignedPayloads = try boundary.store.read(channel: "beta")
        for (fixtureName, label) in [
            ("invalidUTF8", "Signed invalid UTF-8 payload"),
            ("oversizedSequence", "Signed oversized sequence"),
            ("duplicatePayloadKey", "Signed duplicate JSON payload key"),
            ("escapedUnicode", "Signed noncanonical Unicode escape"),
            ("reorderedKeys", "Signed noncanonical JSON field ordering"),
            ("noncanonicalWhitespace", "Signed noncanonical JSON whitespace"),
            ("escapedSlash", "Signed noncanonical escaped slash")
        ] {
            guard let signedCase = fixture.signedNegativeCases[fixtureName] else {
                fatalError("FAIL: Missing negative fixture: \\(fixtureName)")
            }
            try mustReject(label) {
                try boundary.verifyAndRecord(
                    envelopeJSON: try JSONEncoder().encode(signedCase),
                    expectedChannel: "beta", now: now)
            }
        }
        guard try boundary.store.read(channel: "beta") == beforeMalformedSignedPayloads else {
            fatalError("FAIL: Malformed signed payloads changed trusted state")
        }
        print("PASS: Malformed signed payload rejection preserved trusted state")
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

        // Exercise a genuine signed upgrade in its own trusted-state history.
        // The replay tests above deliberately wrote unrelated bytes at sequence 8.
        let upgradeURL = dir.appendingPathComponent("signed-upgrade-sequence.json")
        let upgradeStore = ZagMetadataV2SequenceStore(fileURL: upgradeURL)
        let upgradeBoundary = ZagMetadataV2VerifiedSequence(
            registry: registry, store: upgradeStore)
        try upgradeBoundary.verifyAndRecord(
            envelopeJSON: original, expectedChannel: "beta", now: now)
        let signedUpgrade = try JSONEncoder().encode(fixture.signedHigherSequence)
        try upgradeBoundary.verifyAndRecord(
            envelopeJSON: signedUpgrade, expectedChannel: "beta", now: now)
        guard try upgradeStore.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Signed higher sequence was not persisted")
        }
        print("PASS: Independently signed higher sequence accepted")
        try mustReject("Older signed manifest after verified upgrade") {
            try upgradeBoundary.verifyAndRecord(
                envelopeJSON: original, expectedChannel: "beta", now: now)
        }
        guard try upgradeStore.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Verified upgrade high-water mark changed after replay")
        }
        print("PASS: Verified upgrade remains trusted after old manifest replay")
        // Reopen the upgraded state and exercise the signed verifier boundary
        // again, rather than relying only on the previous store instance.
        let reopenedUpgradeStore = ZagMetadataV2SequenceStore(fileURL: upgradeURL)
        let reopenedUpgradeBoundary = ZagMetadataV2VerifiedSequence(
            registry: registry, store: reopenedUpgradeStore)
        guard try reopenedUpgradeStore.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Verified upgrade was not preserved across restart")
        }
        print("PASS: Verified upgrade high-water mark survives restart")
        try reopenedUpgradeBoundary.verifyAndRecord(
            envelopeJSON: signedUpgrade, expectedChannel: "beta", now: now)
        print("PASS: Identical signed upgraded manifest accepted after restart")
        try mustReject("Older signed manifest after upgraded-state restart") {
            try reopenedUpgradeBoundary.verifyAndRecord(
                envelopeJSON: original, expectedChannel: "beta", now: now)
        }
        guard try reopenedUpgradeStore.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Replayed old manifest changed restarted upgrade state")
        }
        print("PASS: Restarted upgraded state unchanged after rollback rejection")
        // A valid signature is insufficient before the signed publication time.
        let beforeFuturePublication = try reopenedUpgradeStore.read(channel: "beta")
        try mustReject("Not-yet-published signed release") {
            try reopenedUpgradeBoundary.verifyAndRecord(
                envelopeJSON: signedUpgrade, expectedChannel: "beta",
                now: ISO8601DateFormatter().date(from: "2026-10-17T09:59:59Z")!)
        }
        guard try reopenedUpgradeStore.read(channel: "beta") == beforeFuturePublication else {
            fatalError("FAIL: Future-dated signed metadata modified trusted state")
        }
        print("PASS: Future-dated signed release preserved trusted state")
        // The signature is valid for the original pinned identity, but that
        // identity must not be accepted by a registry that does not trust it.
        let untrustedRegistry = try ZagMetadataV2KeyRegistry.production()
        let untrustedBoundary = ZagMetadataV2VerifiedSequence(
            registry: untrustedRegistry, store: reopenedUpgradeStore)
        let beforeUntrustedKey = try reopenedUpgradeStore.read(channel: "beta")
        try mustReject("Valid signature from untrusted signing key") {
            try untrustedBoundary.verifyAndRecord(
                envelopeJSON: signedUpgrade, expectedChannel: "beta", now: now)
        }
        guard try reopenedUpgradeStore.read(channel: "beta") == beforeUntrustedKey else {
            fatalError("FAIL: Untrusted key changed trusted sequence state")
        }
        print("PASS: Untrusted signing key preserved trusted sequence state")
        // Rotate through an overlap registry, then retire the original key.
        // Both manifests are independently signed with deterministic test keys.
        let rotatedEnvelope = try JSONEncoder().encode(fixture.signedRotatedKeyUpgrade)
        let overlapRegistry = try ZagMetadataV2KeyRegistry(anchors: [
            .init(keyID: fixture.envelope.keyId, publicKeyBase64: fixture.publicKeyBase64),
            .init(keyID: fixture.signedRotatedKeyUpgrade.keyId,
                  publicKeyBase64: fixture.rotatedPublicKeyBase64)
        ])
        let overlapBoundary = ZagMetadataV2VerifiedSequence(
            registry: overlapRegistry, store: reopenedUpgradeStore)
        try overlapBoundary.verifyAndRecord(
            envelopeJSON: rotatedEnvelope, expectedChannel: "beta", now: now)
        guard try reopenedUpgradeStore.read(channel: "beta")?.sequence == 9 else {
            fatalError("FAIL: Rotated signing key did not advance trusted sequence")
        }
        print("PASS: Rotated signing key advanced sequence during trust overlap")

        let retiredRegistry = try ZagMetadataV2KeyRegistry(anchors: [
            .init(keyID: fixture.signedRotatedKeyUpgrade.keyId,
                  publicKeyBase64: fixture.rotatedPublicKeyBase64)
        ])
        let retiredBoundary = ZagMetadataV2VerifiedSequence(
            registry: retiredRegistry, store: reopenedUpgradeStore)
        try retiredBoundary.verifyAndRecord(
            envelopeJSON: rotatedEnvelope, expectedChannel: "beta", now: now)
        print("PASS: Rotated key remains trusted after old key retirement")
        let beforeRetiredReplay = try reopenedUpgradeStore.read(channel: "beta")
        try mustReject("Retired signing key after trust rotation") {
            try retiredBoundary.verifyAndRecord(
                envelopeJSON: signedUpgrade, expectedChannel: "beta", now: now)
        }
        guard try reopenedUpgradeStore.read(channel: "beta") == beforeRetiredReplay else {
            fatalError("FAIL: Retired signing key modified sequence state")
        }
        print("PASS: Retired signing key preserved trusted state")
        // Retirement policy is supplied by the app-bundled registry, not
        // persisted release metadata. Reopening the store must not restore
        // authority to a key excluded from the current registry.
        let reopenedRotatedStore = ZagMetadataV2SequenceStore(fileURL: upgradeURL)
        let reopenedRetiredBoundary = ZagMetadataV2VerifiedSequence(
            registry: retiredRegistry, store: reopenedRotatedStore)
        guard try reopenedRotatedStore.read(channel: "beta")?.sequence == 9 else {
            fatalError("FAIL: Rotated sequence was not persisted across restart")
        }
        print("PASS: Rotated signing-key sequence survives restart")
        try reopenedRetiredBoundary.verifyAndRecord(
            envelopeJSON: rotatedEnvelope, expectedChannel: "beta", now: now)
        print("PASS: Rotated signing key remains valid after restart")
        let beforeRestartedRetirement = try reopenedRotatedStore.read(channel: "beta")
        try mustReject("Retired signing key after store restart") {
            try reopenedRetiredBoundary.verifyAndRecord(
                envelopeJSON: signedUpgrade, expectedChannel: "beta", now: now)
        }
        guard try reopenedRotatedStore.read(channel: "beta") == beforeRestartedRetirement else {
            fatalError("FAIL: Retired key changed restarted trusted sequence")
        }
        print("PASS: Retired key rejection preserved state after restart")






        print("SUCCESS: Offline verified-metadata persistence integration tests passed")
    }
}

import Foundation
import CryptoKit
import Security

// Runs the Python reference vector (scripts/zag-v2-test-vector.py) against the
// app's actual verified pipeline: ZagUpdateMetadataV2 verification and
// validation plus the Keychain rollback store. The cases come from the
// October prototype suites (ZagMetadataV2*Tests.swift), which tested
// standalone prototypes; this applies the same corpus to the shipped code.
// Uses only the vector's public test keys and disposable Keychain state.
//
// Output: PASS is a mandatory check that passed. KNOWN GAP is a documented
// discrepancy (docs/UPDATE-METADATA-CONFORMANCE.md) that is still present.
// FAIL is a regression, a new discrepancy, or a change to the known-gap
// inventory; any FAIL makes the suite fail.
//
// Usage: test-zag-v2-vector-conformance <vector.json>
@main
struct ZagV2VectorConformance {
    static var failures = 0
    static var passes = 0
    static var gaps = 0

    static func pass(_ message: String) { print("PASS: \(message)"); passes += 1 }
    static func fail(_ message: String) { print("FAIL: \(message)"); failures += 1 }
    static func gap(_ message: String) { print("KNOWN GAP: \(message)"); gaps += 1 }

    /// A fresh, isolated rollback store, deleted again after `body`.
    static func withStore<T>(_ body: (ZagUpdateRollbackStore) async throws -> T) async rethrows -> T {
        let service = "app.zagstore.ios.vector-conformance.\(UUID().uuidString)"
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        return try await body(ZagUpdateRollbackStore(service: service))
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: test-zag-v2-vector-conformance <vector.json>\n", stderr)
            exit(2)
        }
        let vector = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        ) as! [String: Any]
        let keyID = vector["keyId"] as! String
        let key = Data(base64Encoded: vector["publicKeyBase64"] as! String)!
        let rotatedKey = Data(base64Encoded: vector["rotatedPublicKeyBase64"] as! String)!
        let trusted = [keyID: key]
        let now = ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z")!

        func bytes(_ envelope: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        func accept(_ envelope: Any, keys: [String: Data] = trusted, channel: String = "beta",
                    store: ZagUpdateRollbackStore) async throws -> ZagUpdateMetadataV2.Payload {
            try await ZagUpdateVerifiedPipeline.accept(
                envelope: try bytes(envelope), channel: channel, trustedKeys: keys, store: store, now: now
            )
        }
        func accepted(_ envelope: Any, keys: [String: Data] = trusted, channel: String = "beta") async -> Bool {
            await withStore { store in
                do {
                    _ = try await accept(envelope, keys: keys, channel: channel, store: store)
                    return true
                } catch {
                    return false
                }
            }
        }

        // Baseline and signed positive cases, including Unicode release notes.
        let base = vector["envelope"]!
        await accepted(base) ? pass("reference envelope accepted") : fail("reference envelope rejected")
        for (name, envelope) in (vector["signedPositiveCases"] as! [String: Any]).sorted(by: { $0.key < $1.key }) {
            await accepted(envelope) ? pass("signed positive case \(name) accepted") : fail("signed positive case \(name) rejected")
        }

        // Every signed negative case must be rejected and leave no rollback
        // state, except the documented known gaps below.
        //
        // Known gaps: the app (and the production signer) check only that
        // ipaURL is https on github.com under the releases download path, and
        // that minimumIOSVersion is non-empty, so these cases are still
        // accepted. Exploiting them needs metadata signed by a trusted key, and
        // the downloaded IPA must still match the signed SHA-256. See
        // docs/UPDATE-METADATA-CONFORMANCE.md. When a fix makes one of them
        // fail closed, this suite fails and prints the evidence; then move the
        // case out of this list and the document in the same change.
        // Any negative case not listed here is mandatory.
        let knownGaps: [String: String] = [
            "credentialedIPAURL": "ipaURL carries user:password credentials",
            "emptyReleaseTag": "ipaURL has an empty release tag segment",
            "encodedBackslash": "ipaURL path contains an encoded backslash",
            "encodedDotDotTraversal": "ipaURL path contains an encoded ../ segment",
            "encodedPathSeparator": "ipaURL path contains an encoded / separator",
            "invalidMinimumIOS": "minimumIOSVersion is not a dotted numeric version",
            "ipaPathTraversal": "ipaURL path contains ../ segments",
            "ipaURLWithFragment": "ipaURL has a fragment",
            "ipaURLWithQuery": "ipaURL has a query string",
            "missingReleaseAsset": "ipaURL names a release tag but no asset",
            "unexpectedIPAPort": "ipaURL has an explicit port"
        ]
        let negatives = vector["signedNegativeCases"] as! [String: Any]
        for name in knownGaps.keys.sorted() where negatives[name] == nil {
            fail("known gap \(name) is missing from the vector; update the known-gap inventory")
        }
        for (name, envelope) in negatives.sorted(by: { $0.key < $1.key }) {
            let outcome: (rejection: String?, changedState: Bool) = await withStore { store in
                do {
                    _ = try await accept(envelope, store: store)
                    return (nil, (try? await store.highestAccepted(channel: "beta")) != nil)
                } catch {
                    return (String(describing: error), (try? await store.highestAccepted(channel: "beta")) != nil)
                }
            }
            let description = knownGaps[name]
            switch (outcome.rejection, description) {
            case (nil, let description?):
                gap("\(name) accepted: \(description)")
            case (nil, nil):
                fail("signed negative case \(name) accepted (regression or new discrepancy)")
            case (let error?, _) where outcome.changedState:
                fail("signed negative case \(name) rejected (\(error)) but changed rollback state")
            case (let error?, let description?):
                let payload = (envelope as! [String: Any])["payload"] as! String
                let fields = (try? JSONSerialization.jsonObject(with: Data(base64Encoded: payload)!)) as? [String: Any]
                fail("""
                    known gap \(name) is now rejected; update the known-gap inventory. \
                    Evidence: \(description); ipaURL=\(fields?["ipaURL"] ?? "?"), \
                    minimumIOSVersion=\(fields?["minimumIOSVersion"] ?? "?"); rejected with \(error)
                    """)
            case (let error?, nil):
                pass("signed negative case \(name) rejected (\(error))")
            }
        }

        // Canonical JSON differential: accept exactly what the JCS reference accepts.
        var agreed = 0
        let differential = vector["canonicalDifferentialCases"] as! [String: [String: Any]]
        for (name, testCase) in differential.sorted(by: { $0.key < $1.key }) {
            let expected = testCase["expectedAccepted"] as! Bool
            let actual = await accepted(testCase["envelope"]!)
            if actual == expected {
                agreed += 1
            } else {
                fail("canonical differential \(name): expected \(expected ? "accepted" : "rejected"), got \(actual ? "accepted" : "rejected")")
            }
        }
        if agreed == differential.count {
            pass("canonical differential matches the JCS reference (\(agreed) cases)")
        }

        // Sequence handling across a single channel history.
        await withStore { store in
            do {
                _ = try await accept(base, store: store)
                _ = try await accept(base, store: store)
                pass("identical sequence and payload accepted again")
            } catch {
                fail("identical sequence and payload rejected: \(error)")
            }
            do {
                _ = try await accept(vector["signedEqualSequenceConflict"]!, store: store)
                fail("conflicting payload at an accepted sequence was accepted")
            } catch {
                (try? await store.highestAccepted(channel: "beta")) == 7
                    ? pass("conflicting payload at an accepted sequence rejected, state preserved")
                    : fail("conflicting payload changed the accepted sequence")
            }
            do {
                _ = try await accept(vector["signedHigherSequence"]!, store: store)
                pass("higher sequence accepted")
            } catch {
                fail("higher sequence rejected: \(error)")
            }
            do {
                _ = try await accept(base, store: store)
                fail("replay of an older sequence accepted")
            } catch {
                (try? await store.highestAccepted(channel: "beta")) == 8
                    ? pass("replay of an older sequence rejected, state preserved")
                    : fail("replay changed the accepted sequence")
            }
        }

        // Keys: an envelope verifies only under the key it names.
        let rotated = vector["signedRotatedKeyUpgrade"]!
        await accepted(rotated) ? fail("envelope signed by an untrusted key accepted") : pass("envelope signed by an untrusted key rejected")
        await accepted(rotated, keys: [keyID: key, "zag-v2-rotated-test-only": rotatedKey])
            ? pass("envelope accepted once its signing key is trusted")
            : fail("envelope rejected although its signing key is trusted")
        await accepted(rotated, keys: ["zag-v2-rotated-test-only": key])
            ? fail("signature accepted under the wrong public key")
            : pass("signature under the wrong public key rejected")
        await accepted(base, channel: "stable") ? fail("beta envelope accepted for stable") : pass("beta envelope rejected for stable")

        // Artifact binding: the IPA digest comes from the authenticated payload.
        let artifact = vector["signedArtifactPositive"] as! [String: Any]
        let artifactBytes = Data(base64Encoded: artifact["bytesBase64"] as! String)!
        await withStore { store in
            do {
                let payload = try await accept(artifact["envelope"]!, store: store)
                let digest = SHA256.hash(data: artifactBytes).map { String(format: "%02x", $0) }.joined()
                var tampered = artifactBytes
                tampered[tampered.startIndex] ^= 0x01
                let tamperedDigest = SHA256.hash(data: tampered).map { String(format: "%02x", $0) }.joined()
                payload.sha256 == digest && payload.sha256 != tamperedDigest
                    ? pass("authenticated digest matches the artifact and not a tampered copy")
                    : fail("authenticated digest does not bind the artifact")
            } catch {
                fail("signed artifact metadata rejected: \(error)")
            }
        }

        guard failures == 0 else {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("Summary: \(passes) mandatory checks passed, \(gaps) known gaps present, 0 failures")
        print("SUCCESS: reference vector conformance passed")
    }
}

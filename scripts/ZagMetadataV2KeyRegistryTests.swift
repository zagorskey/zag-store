import Foundation
import CryptoKit

@main
struct ZagMetadataV2KeyRegistryTests {
    static func expectFailure(_ label: String, _ action: () throws -> Void) {
        do {
            try action()
            fatalError("FAIL: \(label) was accepted")
        } catch {
            print("PASS: \(label) rejected")
        }
    }

    static func main() throws {
        // Deterministic public test anchors only. Never use these for releases.
        let first = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let second = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let registry = try ZagMetadataV2KeyRegistry(anchors: [
            .init(keyID: "test-old", publicKeyBase64: first.publicKey.rawRepresentation.base64EncodedString()),
            .init(keyID: "test-new", publicKeyBase64: second.publicKey.rawRepresentation.base64EncodedString())
        ])
        guard try registry.publicKey(for: "test-old").rawRepresentation == first.publicKey.rawRepresentation,
              try registry.publicKey(for: "test-new").rawRepresentation == second.publicKey.rawRepresentation
        else { fatalError("FAIL: key resolution") }
        print("PASS: Two pinned test keys resolved independently")
        let message = Data("ZAG-STORE-UPDATE-V2\\nrotation-test".utf8)
        let oldSignature = try first.signature(for: message)
        let newSignature = try second.signature(for: message)
        guard try registry.publicKey(for: "test-old").isValidSignature(oldSignature, for: message),
              try registry.publicKey(for: "test-new").isValidSignature(newSignature, for: message)
        else { fatalError("FAIL: Valid rotation signatures") }
        print("PASS: Old and new signing keys accepted during rotation")
        guard try !registry.publicKey(for: "test-old").isValidSignature(newSignature, for: message),
              try !registry.publicKey(for: "test-new").isValidSignature(oldSignature, for: message)
        else { fatalError("FAIL: Cross-key signature accepted") }
        print("PASS: Cross-key signatures rejected")

        // Rotation completes by shipping a registry containing only the new anchor.
        let retiredRegistry = try ZagMetadataV2KeyRegistry(anchors: [
            .init(keyID: "test-new", publicKeyBase64: second.publicKey.rawRepresentation.base64EncodedString())
        ])
        guard try retiredRegistry.publicKey(for: "test-new").isValidSignature(newSignature, for: message)
        else { fatalError("FAIL: New signature after retirement") }
        print("PASS: New signing key remains trusted after retirement")
        expectFailure("Retired signing key ID") {
            _ = try retiredRegistry.publicKey(for: "test-old")
        }



        expectFailure("Unknown key ID") { _ = try registry.publicKey(for: "test-unknown") }
        expectFailure("Duplicate key ID") {
            _ = try ZagMetadataV2KeyRegistry(anchors: [
                .init(keyID: "same", publicKeyBase64: first.publicKey.rawRepresentation.base64EncodedString()),
                .init(keyID: "same", publicKeyBase64: second.publicKey.rawRepresentation.base64EncodedString())
            ])
        }
        expectFailure("Empty key ID") {
            _ = try ZagMetadataV2KeyRegistry(anchors: [
                .init(keyID: "", publicKeyBase64: first.publicKey.rawRepresentation.base64EncodedString())
            ])
        }
        expectFailure("Malformed public key") {
            _ = try ZagMetadataV2KeyRegistry(anchors: [
                .init(keyID: "invalid", publicKeyBase64: "not-a-valid-key")
            ])
        }
        let production = try ZagMetadataV2KeyRegistry.production()
        expectFailure("Unprovisioned production registry") {
            _ = try production.publicKey(for: "test-old")
        }
        print("SUCCESS: Pinned public-key registry tests passed")
    }
}

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

        expectFailure("Unknown key ID") { _ = try registry.publicKey(for: "test-unknown") }
        expectFailure("Duplicate key ID") {
            _ = try ZagMetadataV2KeyRegistry(anchors: [
                .init(keyID: "same", publicKeyBase64: first.publicKey.rawRepresentation.base64EncodedString()),
                .init(keyID: "same", publicKeyBase64: second.publicKey.rawRepresentation.base64EncodedString())
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

import Foundation

/// Production trust anchors for Zag Store authenticated update metadata.
///
/// Contains only independently reviewed public Ed25519 trust anchors.
/// Provisioning a public key does not activate v2 discovery or migration.
/// Never add a private key or disposable test key here.
enum ZagUpdateTrustStore {
    /// Stable key IDs mapped to 32-byte Ed25519 raw public keys.
    /// zag-v2-2026-a is retired and deliberately absent.
    /// Production key fingerprint (SHA-256 of 32 raw bytes):
    /// 844fe8a9856d5e7ebc09c94f5d73acb8e61fb0d26a40d6533e3d9ee65616efa0
    private static let productionKeyBytes: [String: Data] = [
        "zag-v2-2026-b": Data([0x97, 0xd3, 0xcd, 0xfa, 0xe4, 0x5c, 0x59, 0x28, 0x0a, 0xd5, 0x46, 0xbc, 0xd4, 0x8f, 0x43, 0xbd, 0xb2, 0x0b, 0x50, 0x3c, 0xad, 0xc1, 0xd7, 0xc0, 0x18, 0xb4, 0xa4, 0x58, 0x93, 0xb3, 0x10, 0x9b])
    ]

    static var productionKeys: [String: Data] {
        productionKeyBytes
    }

    /// Resolve only provisioned keys; never fetch trust anchors from metadata.
    static func publicKey(for keyID: String) -> Data? {
        guard !keyID.isEmpty, keyID.utf8.count <= 64,
              let key = productionKeyBytes[keyID], key.count == 32 else {
            return nil
        }
        return key
    }

    /// Test keys belong in an injected trustedKeys argument of the staged
    /// verification pipeline, not in this production registry.
}

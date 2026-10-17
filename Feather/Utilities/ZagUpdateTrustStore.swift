import Foundation

/// Production trust anchors for Zag Store authenticated update metadata.
///
/// Contains only independently reviewed public Ed25519 trust anchors.
/// Provisioning a public key does not activate v2 discovery or migration.
/// Never add a private key or disposable test key here.
enum ZagUpdateTrustStore {
    /// Stable key IDs mapped to 32-byte Ed25519 raw public keys.
    /// Production key fingerprint (SHA-256 of 32 raw bytes):
    /// 1310a5ac9ccfbc82ac3f3dcb3e6eb1c90fd68fcb1efb3cbf59a647de04568e48
    private static let productionKeyBytes: [String: Data] = [
        "zag-v2-2026-a": Data([0x97, 0xc7, 0x62, 0xc6, 0x06, 0x21, 0x34, 0xd6, 0xc3, 0x81, 0x29, 0x75, 0x10, 0x29, 0x46, 0x3e, 0x0a, 0xd5, 0x1f, 0x56, 0xa2, 0xa4, 0x73, 0xe5, 0xcc, 0x0f, 0xa9, 0x37, 0xd2, 0xd1, 0x2d, 0x6c])
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

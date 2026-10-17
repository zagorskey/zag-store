import Foundation

/// Production trust anchors for Zag Store authenticated update metadata.
///
/// This registry intentionally starts empty. A production Ed25519 public key
/// must be reviewed and provisioned in a separate change before v2 discovery
/// is enabled. Never add a private key or disposable test key here.
enum ZagUpdateTrustStore {
    /// Stable key IDs mapped to 32-byte Ed25519 raw public keys.
    /// Empty means fail closed: no signed v2 manifest can be trusted.
    private static let productionKeyBytes: [String: Data] = [:]

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

import Foundation
import CryptoKit

/// Immutable, app-bundled Ed25519 trust anchors for authenticated v2 metadata.
///
/// Production callers must replace the empty production registry with audited,
/// explicitly provisioned public keys. Never source keys from remote metadata.
struct ZagMetadataV2KeyRegistry {
    enum RegistryError: Error {
        case unknownKey, malformedPublicKey, duplicateKeyID
    }

    struct Anchor {
        let keyID: String
        let publicKeyBase64: String
    }

    private let keys: [String: Curve25519.Signing.PublicKey]

    init(anchors: [Anchor]) throws {
        var resolved: [String: Curve25519.Signing.PublicKey] = [:]
        for anchor in anchors {
            guard !anchor.keyID.isEmpty, resolved[anchor.keyID] == nil else {
                throw RegistryError.duplicateKeyID
            }
            guard let bytes = Data(base64Encoded: anchor.publicKeyBase64),
                  bytes.count == 32,
                  bytes.base64EncodedString() == anchor.publicKeyBase64,
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
            else { throw RegistryError.malformedPublicKey }
            resolved[anchor.keyID] = key
        }
        self.keys = resolved
    }

    func publicKey(for keyID: String) throws -> Curve25519.Signing.PublicKey {
        guard let key = keys[keyID] else { throw RegistryError.unknownKey }
        return key
    }

    /// Intentionally empty until a production signing ceremony provisions keys.
    static func production() throws -> Self {
        try Self(anchors: [])
    }
}

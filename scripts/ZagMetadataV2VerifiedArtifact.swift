import Foundation

/// Offline, read-only integration boundary. Verifies metadata authentication
/// and the exact bytes of a local IPA without recording acceptance or
/// authorizing installation. Identity/entitlements still require review.
struct ZagMetadataV2VerifiedArtifact {
    let registry: ZagMetadataV2KeyRegistry

    func verify(
        envelopeJSON: Data,
        expectedChannel: String,
        now: Date,
        localIPA: URL
    ) throws {
        // The digest must come from this validated signed payload, never from
        // a caller-supplied checksum or unauthenticated JSON field.
        try ZagMetadataV2TestVerifier.verify(
            envelopeJSON: envelopeJSON,
            trustedKeys: registry,
            expectedChannel: expectedChannel,
            now: now
        )
        struct Envelope: Decodable { let payload: String }
        struct SignedDigest: Decodable { let sha256: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: envelopeJSON)
        guard let signedPayload = Data(base64Encoded: envelope.payload) else {
            throw ZagMetadataV2TestVerifier.Failure.invalidPayload
        }
        let checksum = try JSONDecoder().decode(SignedDigest.self, from: signedPayload).sha256
        try ZagMetadataV2ArtifactHash.verify(
            fileURL: localIPA, expectedSHA256: checksum)
    }
}

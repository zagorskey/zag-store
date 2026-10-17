import Foundation
import CryptoKit

/// Offline integration boundary only; not part of Zag Store's live updater.
/// A successful signature and policy verification is required before advancing
/// persistent anti-rollback state. Callers must not install from expired data.
struct ZagMetadataV2VerifiedSequence {
    let registry: ZagMetadataV2KeyRegistry
    let store: ZagMetadataV2SequenceStore

    func verifyAndRecord(
        envelopeJSON: Data,
        expectedChannel: String,
        now: Date
    ) throws {
        try ZagMetadataV2TestVerifier.verify(
            envelopeJSON: envelopeJSON,
            trustedKeys: registry,
            expectedChannel: expectedChannel,
            now: now)

        // Decode only after signature, schema, and timestamp validation.
        struct Envelope: Decodable {
            let payload: String
        }
        struct SignedSequence: Decodable {
            let sequence: Int
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: envelopeJSON)
        guard let payload = Data(base64Encoded: envelope.payload) else {
            throw ZagMetadataV2TestVerifier.Failure.invalidPayload
        }
        let sequence = try JSONDecoder().decode(SignedSequence.self, from: payload).sequence
        do {
            try store.accept(
                channel: expectedChannel,
                sequence: sequence,
                signedPayload: payload)
        } catch ZagMetadataV2SequenceStore.StoreError.publicationUncertain {
            // Rename already occurred; an identical visible snapshot does not
            // establish fsync durability. Preserve the uncertain outcome even
            // when the immediate read matches, so callers cannot install on
            // the strength of an unconfirmed state transition.
            let digest = SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }.joined()
            let observed = try store.read(channel: expectedChannel)
            guard observed?.sequence == sequence,
                  observed?.digest == digest else {
                throw ZagMetadataV2SequenceStore.StoreError.publicationUncertain
            }
            throw ZagMetadataV2SequenceStore.StoreError.publicationUncertain
        }
    }
}

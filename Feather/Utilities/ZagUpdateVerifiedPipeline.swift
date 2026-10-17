import Foundation

/// Staged authenticated v2 pipeline; no production trust keys are installed
/// and the live updater does not invoke this code.
enum ZagUpdateVerifiedPipeline {
    /// Persist rollback state only after cryptographic verification and
    /// complete semantic validation. All failures propagate to the caller.
    static func accept(
        envelope: Data,
        channel: String,
        trustedKeys: [String: Data],
        store: ZagUpdateRollbackStore = .shared,
        now: Date = Date()
    ) async throws -> ZagUpdateMetadataV2.Payload {
        let bytes = try ZagUpdateMetadataV2.verifiedPayload(
            envelope, trustedKeys: trustedKeys
        )
        let payload = try ZagUpdateMetadataV2.validatePayload(
            bytes, channel: channel, now: now
        )
        try await store.recordAccepted(
            sequence: payload.sequence,
            payload: bytes,
            channel: channel
        )
        return payload
    }
}

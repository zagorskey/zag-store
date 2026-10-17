import Foundation

/// Read-only authenticated update metadata discovery for future v2 rollout.
/// Intentionally NOT connected to ZagSelfUpdateCoordinator or live channels.
/// A missing production key must fail closed, before any network request.
enum ZagUpdateV2Discovery {
    enum DiscoveryError: Error {
        case unprovisionedTrust, invalidChannel, insecureURL
        case invalidResponse, httpStatus(Int), oversizedResponse
    }

    static let maximumEnvelopeBytes = 256 * 1024

    /// Fetch only the caller-provided HTTPS endpoint, verify its signed metadata,
    /// and persist accepted rollback state through the staged pipeline.
    /// Tests can inject a disposable trust map; production uses an empty map
    /// until independently reviewed public keys are provisioned.
    static func fetchVerified(
        from url: URL,
        channel: String,
        trustedKeys: [String: Data] = ZagUpdateTrustStore.productionKeys,
        store: ZagUpdateRollbackStore = .shared,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> ZagUpdateMetadataV2.Payload {
        guard ["stable", "beta", "nightly"].contains(channel) else {
            throw DiscoveryError.invalidChannel
        }
        guard !trustedKeys.isEmpty else {
            throw DiscoveryError.unprovisionedTrust
        }
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.host?.lowercased() == "raw.githubusercontent.com",
              url.path.hasPrefix("/zagorskey/zag-store-releases/") else {
            throw DiscoveryError.insecureURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw DiscoveryError.httpStatus(http.statusCode)
        }
        guard data.count <= maximumEnvelopeBytes else {
            throw DiscoveryError.oversizedResponse
        }

        return try await ZagUpdateVerifiedPipeline.accept(
            envelope: data, channel: channel, trustedKeys: trustedKeys,
            store: store, now: now
        )
    }
}

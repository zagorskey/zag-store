import Foundation

/// Decodes Zag Store's versioned artwork metadata contract.
/// The preview endpoint is administrator-only; this client never uses it.
struct ZagGameArtworkResponse: Decodable, Sendable {
    let schemaVersion: Int
    let status: String
    let bundleID: String
    let appleID: Int?
    let screenshotsAvailable: Int
    let artworkURLs: [URL]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case bundleID = "bundle_id"
        case appleID = "apple_id"
        case screenshotsAvailable = "screenshots_available"
        case artworkURLs = "artwork_urls"
    }

    var isVerified: Bool { schemaVersion == 1 && status == "verified" }
}

enum ZagGameArtworkError: Error {
    case endpointNotConfigured
    case invalidBundleID
    case unexpectedResponse
    case unsupportedSchema
    case mismatchedIdentity
}

/// An isolated, opt-in network layer; no UI or repository-refresh coupling.
/// A production endpoint must be explicitly supplied after server rollout.
actor ZagGameArtworkClient {
    static let shared = ZagGameArtworkClient(
        endpoint: URL(string: "https://zagstore.app/wp-json/zag/v1/game-artwork")
    )

    private struct CacheEntry {
        let value: ZagGameArtworkResponse
        let expires: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let session: URLSession
    private let endpoint: URL?

    init(endpoint: URL? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func lookup(bundleID: String, name: String, country: String = "gb") async throws -> ZagGameArtworkResponse {
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let storefront = country.lowercased()
        guard bundle.count <= 255,
              bundle.contains("."),
              !bundle.contains(where: { !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }),
              storefront.count == 2,
              storefront.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw ZagGameArtworkError.invalidBundleID
        }

        let key = storefront + ":" + bundle.lowercased() + ":" + name
        if let hit = cache[key], hit.expires > Date() { return hit.value }

        guard let endpoint,
              endpoint.scheme == "https",
              endpoint.host?.lowercased() == "zagstore.app",
              endpoint.path == "/wp-json/zag/v1/game-artwork" else {
            throw ZagGameArtworkError.endpointNotConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "bundle_id": bundle,
            "name": String(name.prefix(255)),
            "country": storefront
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 128_000 else {
            throw ZagGameArtworkError.unexpectedResponse
        }
        let decoded = try JSONDecoder().decode(ZagGameArtworkResponse.self, from: data)
        guard decoded.schemaVersion == 1 else { throw ZagGameArtworkError.unsupportedSchema }
        guard decoded.bundleID.caseInsensitiveCompare(bundle) == .orderedSame else {
            throw ZagGameArtworkError.mismatchedIdentity
        }
        let sanitized = ZagGameArtworkResponse(
            schemaVersion: decoded.schemaVersion,
            status: decoded.status,
            bundleID: decoded.bundleID,
            appleID: decoded.appleID,
            screenshotsAvailable: decoded.screenshotsAvailable,
            artworkURLs: decoded.isVerified ? decoded.artworkURLs.filter {
                $0.scheme?.lowercased() == "https" &&
                ($0.host?.lowercased() == "mzstatic.com" ||
                 $0.host?.lowercased().hasSuffix(".mzstatic.com") == true)
            } : []
        )
        cache[key] = CacheEntry(value: sanitized, expires: Date().addingTimeInterval(3600))
        return sanitized
    }
}

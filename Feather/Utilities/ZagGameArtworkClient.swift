import Foundation
import ImageIO

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

/// Fetches featured-game imagery without coupling it to repository refreshes.
/// Prefer our controlled bridge; if it verifies a game but publishes no images,
/// look up Apple's public catalogue directly using the exact bundle identifier.
/// This does not copy or redistribute Apple assets through the Zag Store server.
actor ZagGameArtworkClient {
    static let shared = ZagGameArtworkClient(
        endpoint: URL(string: "https://zagstore.app/wp-json/zag/v1/game-artwork")
    )

    private struct CacheEntry {
        let value: ZagGameArtworkResponse
        let expires: Date
    }

    private struct AppleLookup: Decodable {
        let results: [AppleApp]
    }

    private struct AppleApp: Decodable {
        let bundleId: String?
        let kind: String?
        let trackName: String?
        let artistName: String?
        let screenshotUrls: [String]?
        let ipadScreenshotUrls: [String]?
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
              !bundle.contains(where: {
                  !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
              }),
              storefront.count == 2,
              storefront.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw ZagGameArtworkError.invalidBundleID
        }

        let key = storefront + ":" + bundle.lowercased() + ":" + name
        if let hit = cache[key], hit.expires > Date() { return hit.value }

        // The current production bridge confirms identities but intentionally
        // returns artwork_urls: []. Do not treat that empty list as a final result.
        let bridgeResult = try? await fetchFromBridge(bundle: bundle, name: name, country: storefront)
        if let bridgeResult, bridgeResult.isVerified, !bridgeResult.artworkURLs.isEmpty {
            cache[key] = CacheEntry(value: bridgeResult, expires: Date().addingTimeInterval(6 * 3600))
            return bridgeResult
        }

        // Only a catalogue entry whose bundle ID matches exactly can supply art.
        // Never substitute an unrelated game found by title search, or an app icon.
        var appleResult = try? await fetchAppleScreenshots(bundle: bundle, country: storefront)
        // Some games are not listed in the UK storefront, or publish screenshots
        // only in the US catalogue. Retry once without fuzzy title matching.
        if (appleResult?.artworkURLs.isEmpty ?? true) && storefront != "us" {
            if let usResult = try? await fetchAppleScreenshots(bundle: bundle, country: "us"),
               !usResult.artworkURLs.isEmpty {
                appleResult = usResult
            }
        }
        // Resigned repository IPAs frequently use a different bundle ID from
        // the original game. Use exactly ONE full-title match, not fuzzy search.
        if appleResult?.artworkURLs.isEmpty ?? true {
            var titleResult = try? await fetchAppleScreenshotsByExactTitle(
                bundle: bundle, name: name, country: storefront
            )
            if (titleResult?.artworkURLs.isEmpty ?? true) && storefront != "us" {
                if let usResult = try? await fetchAppleScreenshotsByExactTitle(
                    bundle: bundle, name: name, country: "us"
                ), !usResult.artworkURLs.isEmpty {
                    titleResult = usResult
                }
            }
            if let titleResult, !titleResult.artworkURLs.isEmpty {
                appleResult = titleResult
            }
        }
        let result = appleResult ?? bridgeResult ?? ZagGameArtworkResponse(
            schemaVersion: 1,
            status: "unmatched",
            bundleID: bundle,
            appleID: nil,
            screenshotsAvailable: 0,
            artworkURLs: []
        )
        let lifetime: TimeInterval = result.artworkURLs.isEmpty ? 15 * 60 : 6 * 3600
        cache[key] = CacheEntry(value: result, expires: Date().addingTimeInterval(lifetime))
        return result
    }

    private func fetchFromBridge(bundle: String, name: String, country: String) async throws -> ZagGameArtworkResponse {
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
            "country": country
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

        return ZagGameArtworkResponse(
            schemaVersion: 1,
            status: decoded.status,
            bundleID: bundle,
            appleID: decoded.appleID,
            screenshotsAvailable: decoded.screenshotsAvailable,
            artworkURLs: decoded.isVerified ? decoded.artworkURLs.filter(Self.isTrustedImageURL) : []
        )
    }

    private func fetchAppleScreenshots(bundle: String, country: String) async throws -> ZagGameArtworkResponse? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundle),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software")
        ]
        guard let url = components?.url else { throw ZagGameArtworkError.unexpectedResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 512_000 else {
            throw ZagGameArtworkError.unexpectedResponse
        }

        let catalogue = try JSONDecoder().decode(AppleLookup.self, from: data)
        guard let app = catalogue.results.first(where: {
            $0.bundleId?.caseInsensitiveCompare(bundle) == .orderedSame &&
            ($0.kind == nil || $0.kind == "software")
        }) else { return nil }

        return Self.artworkResponse(app, requestedBundle: bundle, status: "verified")
    }

    private func fetchAppleScreenshotsByExactTitle(
        bundle: String, name: String, country: String
    ) async throws -> ZagGameArtworkResponse? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(title.count) else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "30")
        ]
        guard let url = components?.url else {
            throw ZagGameArtworkError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 1_500_000 else {
            throw ZagGameArtworkError.unexpectedResponse
        }

        let catalogue = try JSONDecoder().decode(AppleLookup.self, from: data)
        let matches = catalogue.results.filter {
            ($0.kind == nil || $0.kind == "software") &&
            Self.normalizedTitle($0.trackName ?? "") == Self.normalizedTitle(title) &&
            !Self.normalizedTitle(title).isEmpty &&
            !(($0.screenshotUrls ?? []) + ($0.ipadScreenshotUrls ?? [])).isEmpty
        }

        // A unique, exact title is necessary when the sideloaded bundle ID
        // does not match Apple's. Never silently choose an unrelated search hit.
        guard matches.count == 1, let app = matches.first else { return nil }
        return Self.artworkResponse(app, requestedBundle: bundle, status: "title_matched")
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined()
    }

    private static func artworkResponse(
        _ app: AppleApp, requestedBundle: String, status: String
    ) -> ZagGameArtworkResponse {
        let candidates = (app.screenshotUrls ?? []) + (app.ipadScreenshotUrls ?? [])
        var seen = Set<URL>()
        let images = candidates.compactMap(URL.init(string:)).filter {
            isTrustedImageURL($0) && seen.insert($0).inserted
        }
        let ordered = images.filter(isLandscapeScreenshot) +
            images.filter { !isLandscapeScreenshot($0) }

        return ZagGameArtworkResponse(
            schemaVersion: 1,
            status: status,
            bundleID: requestedBundle,
            appleID: nil,
            screenshotsAvailable: images.count,
            artworkURLs: Array(ordered.prefix(12))
        )
    }

    private static func isTrustedImageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
    }

    private static func isLandscapeScreenshot(_ url: URL) -> Bool {
        // Apple commonly ends screenshots with /1136x640bb.png.
        let parts = url.lastPathComponent.split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1].prefix(while: { $0.isNumber })),
              height > 0 else { return false }
        return Double(width) / Double(height) >= 1.25
    }
}

/// Compressed image bytes and pixel metadata safely cross actor boundaries.
struct ZagFeaturedImageBytes: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

/// Validates actual downloaded image dimensions before using them as hero art.
/// A network error never prevents the app-specific editorial background.
actor ZagFeaturedImageCache {
    static let shared = ZagFeaturedImageCache()

    private var cached: [URL: ZagFeaturedImageBytes] = [:]
    private var cacheOrder: [URL] = []
    private var retryAfter: [URL: Date] = [:]

    func load(_ url: URL) async -> ZagFeaturedImageBytes? {
        guard url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        if let result = cached[url] { return result }
        if let retry = retryAfter[url], retry > Date() { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count >= 2_048,
                  data.count <= 8_000_000,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
                  width >= 550, height >= 450 else {
                retryAfter[url] = Date().addingTimeInterval(180)
                return nil
            }

            let result = ZagFeaturedImageBytes(data: data, width: width, height: height)
            cached[url] = result
            cacheOrder.append(url)
            if cacheOrder.count > 10 {
                cached.removeValue(forKey: cacheOrder.removeFirst())
            }
            return result
        } catch {
            if !Task.isCancelled {
                retryAfter[url] = Date().addingTimeInterval(90)
            }
            return nil
        }
    }
}

import Foundation
import ImageIO
import CryptoKit

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
        let suppliedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        // A modified or malformed sideload identifier is not evidence of an
        // App Store identity. Fall back to the unique exact-title search.
        let validBundle = suppliedBundle.count <= 255 && suppliedBundle.contains(".") &&
            !suppliedBundle.contains(where: {
                !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
            })
        let bundle = validBundle ? suppliedBundle : ""
        let storefront = country.lowercased()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              storefront.count == 2,
              storefront.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw ZagGameArtworkError.invalidBundleID
        }

        let key = storefront + ":" + bundle.lowercased() + ":" + name
        if let hit = cache[key], hit.expires > Date() { return hit.value }

        // Resolve the game's official bundle identity and its exact title
        // concurrently. The production Zag bridge currently returns no URLs,
        // so do not block the Apple lookup waiting for that endpoint.
        async let exactPrimary: ZagGameArtworkResponse? = bundle.isEmpty ? nil :
            (try? await fetchAppleScreenshots(bundle: bundle, country: storefront))
        async let titlePrimary: ZagGameArtworkResponse? =
            try? await fetchAppleScreenshotsByExactTitle(
                bundle: bundle, name: name, country: storefront
            )

        let primaryResults = [await exactPrimary, await titlePrimary]
        var found = primaryResults.compactMap { $0 }.first {
            !$0.artworkURLs.isEmpty
        }

        // A title may exist only in the US storefront. Still insist on an
        // exact title match: never show artwork from a similarly named app.
        if found == nil && storefront != "us" {
            async let exactUS: ZagGameArtworkResponse? = bundle.isEmpty ? nil :
                (try? await fetchAppleScreenshots(bundle: bundle, country: "us"))
            async let titleUS: ZagGameArtworkResponse? =
                try? await fetchAppleScreenshotsByExactTitle(
                    bundle: bundle, name: name, country: "us"
                )
            found = [await exactUS, await titleUS].compactMap { $0 }.first {
                !$0.artworkURLs.isEmpty
            }
        }

        // Retain support for a future curated Zag artwork catalogue, without
        // letting today's empty production response delay ordinary screenshots.
        let bridgeResult: ZagGameArtworkResponse? = found == nil && !bundle.isEmpty ?
            (try? await fetchFromBridge(bundle: bundle, name: name, country: storefront)) : nil
        let result = found ?? bridgeResult ?? ZagGameArtworkResponse(
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

    // Persistent verified bytes; iOS may purge this cache whenever it needs space.
    private static let diskDirectory: URL = {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("ZagFeaturedArtwork", isDirectory: true)
    }()

    private static func fileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(hash + ".image")
    }

    private static func validImage(_ data: Data) -> ZagFeaturedImageBytes? {
        guard (2_048...12_000_000).contains(data.count),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width >= 300, height >= 170 else { return nil }
        return ZagFeaturedImageBytes(data: data, width: width, height: height)
    }

    private func remember(_ image: ZagFeaturedImageBytes, for url: URL) {
        if cached[url] == nil { cacheOrder.append(url) }
        cached[url] = image
        while cacheOrder.count > 16 {
            cached.removeValue(forKey: cacheOrder.removeFirst())
        }
        retryAfter[url] = nil
    }

    private static func pruneDiskCache() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= 96 || bytes > 180_000_000 {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }

    func load(_ url: URL) async -> ZagFeaturedImageBytes? {
        guard url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        if let result = cached[url] { return result }
        let file = Self.fileURL(for: url)
        if let data = try? Data(contentsOf: file),
           let verified = Self.validImage(data) {
            remember(verified, for: url)
            return verified
        }
        if let retry = retryAfter[url], retry > Date() { return nil }

        // A 392x696bb.png Apple URL is a thumbnail request, not a maximum
        // resolution. Ask Apple's CDN for the larger rendition first, then
        // always try the exact supplied URL if that request fails.
        for candidateURL in Self.imageVariants(for: url) {
            guard !Task.isCancelled else { return nil }
            var request = URLRequest(url: candidateURL)
            request.timeoutInterval = 8
            request.cachePolicy = .returnCacheDataElseLoad

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let result = Self.validImage(data) else { continue }

                remember(result, for: url)
                try? FileManager.default.createDirectory(
                    at: Self.diskDirectory, withIntermediateDirectories: true
                )
                try? data.write(to: file, options: .atomic)
                Self.pruneDiskCache()
                return result
            } catch {
                // A blocked or unsupported CDN size does not block the
                // original screenshot from loading.
                continue
            }
        }
        if !Task.isCancelled {
            retryAfter[url] = Date().addingTimeInterval(90)
        }
        return nil
    }

    private static func imageVariants(for url: URL) -> [URL] {
        guard let host = url.host?.lowercased(),
              (host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")),
              url.path.contains("/image/thumb/") else { return [url] }

        let filename = url.lastPathComponent
        guard filename.range(
            of: #"^\d+x\d+(?:bb|w|ss)\.(?:png|jpg|jpeg|webp)$"#,
            options: .regularExpression
        ) != nil else { return [url] }

        let ext = String(filename.split(separator: ".").last ?? "png")
        let directory = url.deletingLastPathComponent()
        let ultraHD = directory.appendingPathComponent("2048x0w." + ext)
        let hd = directory.appendingPathComponent("1200x0w." + ext)
        // Prefer a larger original CDN rendition when supported. Some
        // image endpoints only support 1200px or the supplied URL.
        return [ultraHD, hd, url].reduce(into: [URL]()) { urls, candidate in
            if !urls.contains(candidate) { urls.append(candidate) }
        }
    }
}


/// A Featured card exists only after authentic screenshots have been fetched,
/// decoded and checked for usable dimensions.
struct ZagVerifiedFeaturedArtwork: Sendable {
    enum Layout: Sendable {
        case landscape
        case portraits
        case landscapeStrips
    }
    let layout: Layout
    let images: [ZagFeaturedImageBytes]
}

/// Resolve repository screenshots and exact-identity/title App Store images
/// independently. Failed entries are skipped instead of featured as gradients.
actor ZagFeaturedArtworkResolver {
    static let shared = ZagFeaturedArtworkResolver()

    func resolve(
        bundleID: String?,
        name: String,
        repositoryScreenshots: [URL]
    ) async -> ZagVerifiedFeaturedArtwork? {
        await withTaskGroup(of: ZagVerifiedFeaturedArtwork?.self) { group in
            if !repositoryScreenshots.isEmpty {
                group.addTask { await Self.resolveImages(repositoryScreenshots) }
            }
            group.addTask {
                guard let response = try? await ZagGameArtworkClient.shared.lookup(
                    bundleID: bundleID ?? "", name: name
                ), !response.artworkURLs.isEmpty else { return nil }
                return await Self.resolveImages(response.artworkURLs)
            }

            for await artwork in group {
                if Task.isCancelled {
                    group.cancelAll()
                    return nil
                }
                if let artwork {
                    group.cancelAll()
                    return artwork
                }
            }
            return nil
        }
    }

    private static func resolveImages(_ urls: [URL]) async -> ZagVerifiedFeaturedArtwork? {
        var seen = Set<URL>()
        let candidates = Array(urls.filter { seen.insert($0).inserted }.prefix(8))
        guard !candidates.isEmpty else { return nil }

        return await withTaskGroup(
            of: ZagFeaturedImageBytes?.self,
            returning: ZagVerifiedFeaturedArtwork?.self
        ) { group in
            for url in candidates {
                group.addTask { await ZagFeaturedImageCache.shared.load(url) }
            }
            var portraits: [ZagFeaturedImageBytes] = []
            var landscapes: [ZagFeaturedImageBytes] = []

            for await candidate in group {
                if Task.isCancelled {
                    group.cancelAll()
                    return nil
                }
                guard let candidate, candidate.height > 0 else { continue }
                let ratio = Double(candidate.width) / Double(candidate.height)

                if ratio >= 1.25 {
                    if candidate.width >= 850 && candidate.height >= 420 {
                        group.cancelAll()
                        return ZagVerifiedFeaturedArtwork(layout: .landscape, images: [candidate])
                    }
                    if candidate.width >= 320 && candidate.height >= 175 {
                        landscapes.append(candidate)
                    }
                } else if (0.35...0.90).contains(ratio),
                          candidate.width >= 320 && candidate.height >= 550 {
                    portraits.append(candidate)
                }
            }
            if !portraits.isEmpty {
                return ZagVerifiedFeaturedArtwork(layout: .portraits, images: Array(portraits.prefix(3)))
            }
            if !landscapes.isEmpty {
                return ZagVerifiedFeaturedArtwork(layout: .landscapeStrips, images: Array(landscapes.prefix(3)))
            }
            return nil
        }
    }
}

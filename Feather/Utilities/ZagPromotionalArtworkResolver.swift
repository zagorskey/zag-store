//
//  ZagPromotionalArtworkResolver.swift
//  Feather
//
//  A promotional image is a separate asset from a device screenshot.
//  Sources: explicit repository banner, a small reviewed publisher-art
//  catalogue, or an app-specific image on its verified developer website.
//  App Store screenshot URLs are NEVER inputs to this resolver.
//

import Foundation

actor ZagPromotionalArtworkResolver {
    static let shared = ZagPromotionalArtworkResolver()

    private struct WebsiteCacheEntry {
        let imageURL: URL?
        let expires: Date
    }

    private var websiteCache: [String: WebsiteCacheEntry] = [:]

    func resolve(
        bundleID: String?,
        name: String,
        declaredURL: URL?,
        screenshotURLs: [URL]
    ) async -> ZagFeaturedImageBytes? {
        let screenshotSet = Set(screenshotURLs.map(\.absoluteString))
        var candidates: [URL] = []

        if let declaredURL { candidates.append(declaredURL) }
        if let curated = Self.curatedArtwork(bundleID: bundleID, name: name) {
            candidates.append(curated)
        }

        for url in candidates {
            if let image = await verifiedBanner(url, excluding: screenshotSet) {
                return image
            }
        }

        // Apple only supplies device screenshots, not promotional banners.
        // We consult its verified app identity for a developer website,
        // then look for an independent, genuinely widescreen social image.
        if let website = await officialWebsite(bundleID: bundleID, name: name),
           let banner = await websiteBanner(website, name: name) {
            return await verifiedBanner(banner, excluding: screenshotSet)
        }
        return nil
    }

    private func verifiedBanner(
        _ url: URL,
        excluding screenshotURLs: Set<String>
    ) async -> ZagFeaturedImageBytes? {
        guard Self.isPublicHTTPS(url),
              !screenshotURLs.contains(url.absoluteString),
              let image = await ZagFeaturedImageCache.shared.load(url),
              image.width >= 900, image.height >= 300 else { return nil }

        let ratio = Double(image.width) / Double(image.height)
        guard (1.35...4.2).contains(ratio) else { return nil }
        return image
    }

    // Independently published promotional/marketing art (not App Store
    // screenshots). Curated per product, with no fuzzy title matching.
    private static func curatedArtwork(bundleID: String?, name: String) -> URL? {
        let title = normalized(name)
        let bundle = bundleID?.lowercased() ?? ""

        if bundle == "com.hutchgames.rebelracing" || title == "rebelracing" {
            return URL(string:
                "https://img2.storyblok.com/1920x0/filters%3Aquality%2880%29%3Aformat%28jpg%29/f/138645/1920x1052/5b68ebbdb6/rebel-racing-background.jpeg"
            )
        }
        if bundle == "com.cloud-compiler" ||
           title == "codesnackide" || title == "codesnackideaicodingagent" {
            return URL(string:
                "https://d1iiooxwdowqwr.cloudfront.net/pub/blogimages/20220208171725_codesnackide.png"
            )
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }

    private static func isPublicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              host != "localhost", !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else { return false }
        // Do not contact raw IP addresses, including private-network services.
        let ipv4 = host.split(separator: ".")
        if ipv4.count == 4 && ipv4.allSatisfy({ Int($0) != nil }) { return false }
        if host.contains(":") { return false }
        return true
    }

    private func officialWebsite(bundleID: String?, name: String) async -> URL? {
        let supplied = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !supplied.isEmpty, supplied.contains(".") {
            if let item = await appleCatalogue(
                endpoint: "lookup", parameters: [
                    URLQueryItem(name: "bundleId", value: supplied),
                    URLQueryItem(name: "country", value: "gb"),
                    URLQueryItem(name: "entity", value: "software")
                ]
            ).first(where: {
                (($0["bundleId"] as? String)?.caseInsensitiveCompare(supplied)) == .orderedSame
            }), let website = (item["sellerUrl"] as? String).flatMap(URL.init(string:)),
               Self.isPublicHTTPS(website) {
                return website
            }
        }

        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...100).contains(title.count) else { return nil }
        let results = await appleCatalogue(
            endpoint: "search", parameters: [
                URLQueryItem(name: "term", value: title),
                URLQueryItem(name: "country", value: "gb"),
                URLQueryItem(name: "entity", value: "software"),
                URLQueryItem(name: "limit", value: "30")
            ]
        ).filter {
            Self.normalized($0["trackName"] as? String ?? "") == Self.normalized(title)
        }
        guard results.count == 1,
              let website = (results[0]["sellerUrl"] as? String).flatMap(URL.init(string:)),
              Self.isPublicHTTPS(website) else { return nil }
        return website
    }

    private func appleCatalogue(
        endpoint: String, parameters: [URLQueryItem]
    ) async -> [[String: Any]] {
        var components = URLComponents(string: "https://itunes.apple.com/" + endpoint)
        components?.queryItems = parameters
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200, data.count <= 1_500_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results
    }

    private func websiteBanner(_ website: URL, name: String) async -> URL? {
        let key = website.absoluteString
        if let cached = websiteCache[key], cached.expires > Date() {
            return cached.imageURL
        }
        let url = await discoverWebsiteBanner(website, name: name)
        websiteCache[key] = WebsiteCacheEntry(
            imageURL: url, expires: Date().addingTimeInterval(url == nil ? 1800 : 21600)
        )
        return url
    }

    private func discoverWebsiteBanner(_ website: URL, name: String) async -> URL? {
        var request = URLRequest(url: website)
        request.timeoutInterval = 8
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= 500_000,
              let html = String(data: data, encoding: .utf8) else { return nil }

        let tags = Self.metaTags(in: html)
        let pageName = tags["og:title"] ?? Self.htmlTitle(in: html) ?? ""
        // Generic corporate homepages must not lend their artwork to all apps.
        let needle = Self.normalized(name)
        let documentTitle = Self.normalized(pageName)
        guard needle.count >= 5,
              documentTitle.contains(needle) || needle.contains(documentTitle) &&
              documentTitle.count >= 5 else { return nil }

        let imageValue = tags["og:image:secure_url"] ??
            tags["og:image"] ?? tags["twitter:image"] ?? tags["twitter:image:src"]
        guard let imageValue,
              let imageURL = URL(string: imageValue, relativeTo: website)?.absoluteURL,
              Self.isPublicHTTPS(imageURL) else { return nil }
        return imageURL
    }

    private static func metaTags(in html: String) -> [String: String] {
        guard let tagPattern = try? NSRegularExpression(
            pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive
        ), let attributePattern = try? NSRegularExpression(
            pattern: #"([a-zA-Z:-]+)\s*=\s*["']([^"']+)["']"#,
            options: .caseInsensitive
        ) else { return [:] }

        let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var result: [String: String] = [:]
        for match in tagPattern.matches(in: html, range: htmlRange).prefix(100) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            let tagRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            var attributes: [String: String] = [:]
            for attr in attributePattern.matches(in: tag, range: tagRange) {
                guard let keyRange = Range(attr.range(at: 1), in: tag),
                      let valRange = Range(attr.range(at: 2), in: tag) else { continue }
                attributes[String(tag[keyRange]).lowercased()] = String(tag[valRange])
            }
            if let key = attributes["property"] ?? attributes["name"],
               let value = attributes["content"] {
                result[key.lowercased()] = value.replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        return result
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let pattern = try? NSRegularExpression(
            pattern: #"<title[^>]*>([^<]+)</title>"#, options: .caseInsensitive
        ), let match = pattern.firstMatch(
            in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)
        ), let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}

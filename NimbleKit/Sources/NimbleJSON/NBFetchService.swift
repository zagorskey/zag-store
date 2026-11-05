//
//  FetchService.swift
//  Loader
//
//  Created by samara on 14.03.2025.
//

import Foundation

// MARK: - Repository diagnostics

public struct NBRepositoryFetchMetric: Codable, Identifiable, Sendable {
	public let url: String
	public let status: String
	public let byteCount: Int
	public let networkSeconds: Double
	public let decodeSeconds: Double
	public let recordedAt: Date
	/// HTTP status of this attempt, when a response arrived.
	public var httpStatus: Int? = nil
	/// Content-Length announced by the server, when known.
	public var expectedBytes: Int64? = nil
	/// Why the attempt failed (then a cached copy or nothing was used).
	public var error: String? = nil
	public var startedAt: Date? = nil

	public var id: String { url }
}

/// Stored in a file rather than UserDefaults. A metric is recorded for every
/// repository on every refresh, and each UserDefaults write re-evaluates every
/// SwiftUI view holding @AppStorage, including the app's root tab view, while
/// the refresh animation is running.
public enum NBRepositoryFetchDiagnostics {
	/// Where builds before the file store kept the metrics.
	private static let legacyKey = "ZagStore.RepositoryFetchMetrics"
	private static let lock = NSLock()
	private static let fileURL: URL? = FileManager.default
		.urls(for: .cachesDirectory, in: .userDomainMask)
		.first?
		.appendingPathComponent("ZagStore-RepositoryFetchMetrics.json")

	public static var metrics: [NBRepositoryFetchMetric] {
		lock.lock(); defer { lock.unlock() }
		return load().sorted { $0.recordedAt > $1.recordedAt }
	}

	/// The latest metric for one repository URL.
	public static func metric(for url: String) -> NBRepositoryFetchMetric? {
		lock.lock(); defer { lock.unlock() }
		return load().first { $0.url == url }
	}

	public static func record(_ metric: NBRepositoryFetchMetric) {
		lock.lock(); defer { lock.unlock() }
		var current = load().filter { $0.url != metric.url }
		current.append(metric)
		guard let fileURL, let data = try? JSONEncoder().encode(current) else { return }
		try? data.write(to: fileURL, options: .atomic)
		// One-time migration: the file now holds the older metrics as well.
		if UserDefaults.standard.object(forKey: legacyKey) != nil {
			UserDefaults.standard.removeObject(forKey: legacyKey)
		}
	}

	public static func clear() {
		lock.lock(); defer { lock.unlock() }
		if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
		if UserDefaults.standard.object(forKey: legacyKey) != nil {
			UserDefaults.standard.removeObject(forKey: legacyKey)
		}
	}

	/// Caller holds `lock`.
	private static func load() -> [NBRepositoryFetchMetric] {
		let data = fileURL.flatMap { try? Data(contentsOf: $0) }
			?? UserDefaults.standard.data(forKey: legacyKey)
		guard let data,
			let decoded = try? JSONDecoder().decode([NBRepositoryFetchMetric].self, from: data)
		else { return [] }
		return decoded
	}
}

// MARK: - Class
public class NBFetchService {

	public enum NBFetchServiceError: Error, LocalizedError {
		case invalidURL
		case networkError(Error)
		case noData
		case parsingError(Error)
		case partialData(received: Int, expected: Int64)

		public var errorDescription: String? {
			switch self {
			case .invalidURL: "The URL is invalid."
			case .networkError(let error): "Network error: \(error.localizedDescription)"
			case .noData: "No data received."
			case .parsingError(let error): "Failed to parse data: \(error.localizedDescription)"
			case .partialData(let received, let expected): "Incomplete download: \(received) of \(expected) bytes."
			}
		}
	}

	private struct DecodedCacheEntry {
		let value: Any
		let byteCost: Int
		var lastAccess: UInt64
	}

	private let decodedCacheQueue = DispatchQueue(
		label: "NBFetchService.decoded-cache"
	)
	private var decodedCache: [String: DecodedCacheEntry] = [:]
	private var decodedCacheByteCost = 0
	private var decodedCacheClock: UInt64 = 0
	private let decodedCacheByteLimit = 64 * 1024 * 1024
	private let slowDecodeThreshold: TimeInterval = 0.5

	public init() {}

	private func cachedDecodedValue<T>(
		for url: URL,
		as type: T.Type
	) -> T? {
		decodedCacheQueue.sync {
			let key = url.absoluteString
			guard var entry = decodedCache[key],
			      let value = entry.value as? T else {
				return nil
			}
			decodedCacheClock &+= 1
			entry.lastAccess = decodedCacheClock
			decodedCache[key] = entry
			return value
		}
	}

	private func storeDecodedValue<T>(
		_ value: T,
		for url: URL,
		byteCost: Int
	) {
		decodedCacheQueue.sync {
			let key = url.absoluteString
			if let previous = decodedCache.removeValue(forKey: key) {
				decodedCacheByteCost -= previous.byteCost
			}

			decodedCacheClock &+= 1
			decodedCache[key] = DecodedCacheEntry(
				value: value,
				byteCost: byteCost,
				lastAccess: decodedCacheClock
			)
			decodedCacheByteCost += byteCost

			while decodedCacheByteCost > decodedCacheByteLimit,
			      decodedCache.count > 1,
			      let victim = decodedCache.min(by: {
				      $0.value.lastAccess < $1.value.lastAccess
			      }) {
				decodedCache.removeValue(forKey: victim.key)
				decodedCacheByteCost -= victim.value.byteCost
			}
		}
	}

	public func removeCachedRepository(for url: URL) {
		decodedCacheQueue.sync {
			if let removed = decodedCache.removeValue(forKey: url.absoluteString) {
				decodedCacheByteCost -= removed.byteCost
			}
		}

		if let payloadURL = payloadURL(for: url) {
			try? FileManager.default.removeItem(at: payloadURL)
		}

		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: validatorKey("etag", url: url))
		defaults.removeObject(forKey: validatorKey("modified", url: url))
	}

	/// Every UserDefaults write re-evaluates all @AppStorage views (the root
	/// tab view among them), so an unchanged validator is not written again.
	private func storeValidator(_ value: String, forKey key: String) {
		let defaults = UserDefaults.standard
		guard defaults.string(forKey: key) != value else { return }
		defaults.set(value, forKey: key)
	}

	public func retainCachedRepositories(for urls: Set<URL>) {
		let retainedKeys = Set(urls.map(\.absoluteString))
		decodedCacheQueue.sync {
			for key in decodedCache.keys where !retainedKeys.contains(key) {
				if let removed = decodedCache.removeValue(forKey: key) {
					decodedCacheByteCost -= removed.byteCost
				}
			}
		}
	}

	private static let cacheDirectory: URL? = {
		guard let root = FileManager.default.urls(
			for: .cachesDirectory,
			in: .userDomainMask
		).first else {
			return nil
		}

		let directory = root.appendingPathComponent(
			"ZagStoreRepositoryCache",
			isDirectory: true
		)
		try? FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		return directory
	}()

	private func cacheKey(for url: URL) -> String {
		Data(url.absoluteString.utf8)
			.base64EncodedString()
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "=", with: "")
	}

	private func payloadURL(for url: URL) -> URL? {
		Self.cacheDirectory?
			.appendingPathComponent(cacheKey(for: url))
			.appendingPathExtension("json")
	}

	private func validatorKey(_ name: String, url: URL) -> String {
		"NBFetchService.\(name)." + cacheKey(for: url)
	}
	// Reuse the last valid repository when a refresh cannot provide valid JSON.
	private func completeFromCache<T: Decodable>(
		url: URL,
		cachedData: Data?,
		networkElapsed: Double,
		failure: Error,
		response: HTTPURLResponse? = nil,
		receivedBytes: Int = 0,
		startedAt: Date? = nil,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		func record(_ status: String, bytes: Int) {
			var metric = NBRepositoryFetchMetric(
				url: url.absoluteString,
				status: status,
				byteCount: bytes,
				networkSeconds: networkElapsed,
				decodeSeconds: 0,
				recordedAt: Date()
			)
			metric.httpStatus = response?.statusCode
			metric.expectedBytes = response.flatMap { $0.expectedContentLength > 0 ? $0.expectedContentLength : nil }
			metric.error = failure.localizedDescription
			metric.startedAt = startedAt
			NBRepositoryFetchDiagnostics.record(metric)
		}
		if let decoded: T = cachedDecodedValue(for: url, as: T.self) {
			record("decoded-cache/fallback", bytes: receivedBytes)
			print("[Zag Store Sources] Cache fallback (decoded): \(url.host ?? url.absoluteString) — \(failure.localizedDescription)")
			completion(.success(decoded))
			return
		}
		if let cachedData,
		   let decoded = try? JSONDecoder().decode(T.self, from: cachedData) {
			storeDecodedValue(decoded, for: url, byteCost: cachedData.count)
			record("disk-cache/fallback", bytes: receivedBytes)
			print("[Zag Store Sources] Cache fallback: \(url.host ?? url.absoluteString) — \(failure.localizedDescription)")
			completion(.success(decoded))
			return
		}
		record("failed", bytes: receivedBytes)
		completion(.failure(failure))
	}
}

// MARK: - Class extension: fetch
extension NBFetchService {
	public func fetch<T: Decodable>(
		from urlString: String,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		guard let url = URL(string: urlString) else {
			completion(.failure(NBFetchServiceError.invalidURL))
			return
		}

		fetch(from: url, completion: completion)
	}

	public func fetch<T: Decodable>(
		from url: URL,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		DispatchQueue.global(qos: .userInitiated).async {
			let payloadURL = self.payloadURL(for: url)
			let cachedData = payloadURL.flatMap {
				try? Data(contentsOf: $0, options: .mappedIfSafe)
			}

			var request = URLRequest(url: url)
			if cachedData != nil {
				let defaults = UserDefaults.standard
				if let etag = defaults.string(
					forKey: self.validatorKey("etag", url: url)
				) {
					request.setValue(etag, forHTTPHeaderField: "If-None-Match")
				}
				if let modified = defaults.string(
					forKey: self.validatorKey("modified", url: url)
				) {
					request.setValue(
						modified,
						forHTTPHeaderField: "If-Modified-Since"
					)
				}
			}

			let requestStartedAt = CFAbsoluteTimeGetCurrent()
			let startedAtDate = Date()
			URLSession.shared.dataTask(with: request) { data, response, error in
				let networkElapsed = CFAbsoluteTimeGetCurrent() - requestStartedAt
				let http = response as? HTTPURLResponse
				let received = data?.count ?? 0


				if let error {
					self.completeFromCache(url: url, cachedData: cachedData, networkElapsed: networkElapsed, failure: NBFetchServiceError.networkError(error), response: http, receivedBytes: received, startedAt: startedAtDate, completion: completion)
					return
				}

				if let http, http.statusCode != 304,
				   !(200...299).contains(http.statusCode) {
					self.completeFromCache(url: url, cachedData: cachedData, networkElapsed: networkElapsed, failure: NBFetchServiceError.networkError(
						NSError(domain: "NBFetchService.HTTP", code: http.statusCode,
							userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
					), response: http, receivedBytes: received, startedAt: startedAtDate, completion: completion)
					return
				}

				let responseData: Data
				let sourceLabel: String

				if http?.statusCode == 304, let cachedData {
					responseData = cachedData
					sourceLabel = "disk-cache/304"
				} else if http?.statusCode == 304 {
					self.completeFromCache(url: url, cachedData: cachedData, networkElapsed: networkElapsed, failure: NBFetchServiceError.noData, response: http, receivedBytes: received, startedAt: startedAtDate, completion: completion)
					return
				} else if let data, let http, http.expectedContentLength > 0,
				          Int64(data.count) < http.expectedContentLength {
					// A body shorter than its Content-Length is a cut-off
					// download: never parse or commit it.
					self.completeFromCache(url: url, cachedData: cachedData, networkElapsed: networkElapsed, failure: NBFetchServiceError.partialData(received: data.count, expected: http.expectedContentLength), response: http, receivedBytes: received, startedAt: startedAtDate, completion: completion)
					return
				} else if let data {
					responseData = data
					sourceLabel = "network/\(http?.statusCode ?? 0)"
				} else {
					self.completeFromCache(url: url, cachedData: cachedData, networkElapsed: networkElapsed, failure: NBFetchServiceError.noData, response: http, receivedBytes: received, startedAt: startedAtDate, completion: completion)
					return
				}

				if http?.statusCode == 304,
				   let decoded: T = self.cachedDecodedValue(for: url, as: T.self) {
					var metric = NBRepositoryFetchMetric(
						url: url.absoluteString,
						status: "decoded-cache/304",
						byteCount: responseData.count,
						networkSeconds: networkElapsed,
						decodeSeconds: 0,
						recordedAt: Date()
					)
					metric.httpStatus = 304
					metric.startedAt = startedAtDate
					NBRepositoryFetchDiagnostics.record(metric)
					print(
						"[Zag Store Sources] " +
							"\(url.host ?? url.absoluteString) — decoded-cache/304 — " +
							"\(ByteCountFormatter.string(fromByteCount: Int64(responseData.count), countStyle: .file)) — " +
							"network " + String(format: "%.3fs", networkElapsed) +
							" — decode 0.000s"
					)
					completion(.success(decoded))
					return
				}

				let decodeStartedAt = CFAbsoluteTimeGetCurrent()
				do {
					let decodedData = try JSONDecoder().decode(T.self, from: responseData)
					let decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStartedAt
					self.storeDecodedValue(
						decodedData,
						for: url,
						byteCost: responseData.count
					)

					if decodeElapsed >= self.slowDecodeThreshold {
						print(
							"[Zag Store Sources] Slow decode — " +
							"\(url.host ?? url.absoluteString) — " +
							String(format: "%.3fs", decodeElapsed) +
							" — " +
							ByteCountFormatter.string(
								fromByteCount: Int64(responseData.count),
								countStyle: .file
							)
						)
					}

					if http?.statusCode != 304, let payloadURL {
						do {
							try responseData.write(to: payloadURL, options: .atomic)
							if let etag = http?.value(forHTTPHeaderField: "ETag") {
								self.storeValidator(etag, forKey: self.validatorKey("etag", url: url))
							}
							if let modified = http?.value(forHTTPHeaderField: "Last-Modified") {
								self.storeValidator(modified, forKey: self.validatorKey("modified", url: url))
							}
						} catch {
							print(
								"[Zag Store Sources] Cache write failed: " +
								"\(url.host ?? url.absoluteString) — " +
								error.localizedDescription
							)
						}
					}

					var metric = NBRepositoryFetchMetric(
						url: url.absoluteString,
						status: sourceLabel,
						byteCount: responseData.count,
						networkSeconds: networkElapsed,
						decodeSeconds: decodeElapsed,
						recordedAt: Date()
					)
					metric.httpStatus = http?.statusCode
					metric.expectedBytes = http.flatMap { $0.expectedContentLength > 0 ? $0.expectedContentLength : nil }
					metric.startedAt = startedAtDate
					NBRepositoryFetchDiagnostics.record(metric)
					print(
						"[Zag Store Sources] " +
						"\(url.host ?? url.absoluteString) — \(sourceLabel) — " +
						"\(ByteCountFormatter.string(fromByteCount: Int64(responseData.count), countStyle: .file)) — " +
						"network " + String(format: "%.3fs", networkElapsed) +
						" — decode " + String(format: "%.3fs", decodeElapsed)
					)
					completion(.success(decodedData))
				} catch {
					// Never replace the last-known-good payload unless the new
					// response decoded successfully.
					self.completeFromCache(url: url, cachedData: cachedData, networkElapsed: networkElapsed, failure: NBFetchServiceError.parsingError(error), response: http, receivedBytes: received, startedAt: startedAtDate, completion: completion)
				}
			}.resume()
		}
	}
}

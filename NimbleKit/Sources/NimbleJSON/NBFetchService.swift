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

	public var id: String { url }
}

public enum NBRepositoryFetchDiagnostics {
	private static let key = "ZagStore.RepositoryFetchMetrics"

	public static var metrics: [NBRepositoryFetchMetric] {
		guard
			let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode([NBRepositoryFetchMetric].self, from: data)
		else { return [] }
		return decoded.sorted { $0.recordedAt > $1.recordedAt }
	}

	public static func record(_ metric: NBRepositoryFetchMetric) {
		var current = metrics.filter { $0.url != metric.url }
		current.append(metric)
		if let data = try? JSONEncoder().encode(current) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}

	public static func clear() {
		UserDefaults.standard.removeObject(forKey: key)
	}
}

// MARK: - Class
public class NBFetchService {

	public enum NBFetchServiceError: Error, LocalizedError {
		case invalidURL
		case networkError(Error)
		case noData
		case parsingError(Error)

		public var errorDescription: String? {
			switch self {
			case .invalidURL: "The URL is invalid."
			case .networkError(let error): "Network error: \(error.localizedDescription)"
			case .noData: "No data received."
			case .parsingError(let error): "Failed to parse data: \(error.localizedDescription)"
			}
		}
	}

	private let decodedCacheQueue = DispatchQueue(
		label: "NBFetchService.decoded-cache",
		attributes: .concurrent
	)
	private var decodedCache: [String: Any] = [:]

	public init() {}

	private func cachedDecodedValue<T>(
		for url: URL,
		as type: T.Type
	) -> T? {
		decodedCacheQueue.sync {
			decodedCache[url.absoluteString] as? T
		}
	}

	private func storeDecodedValue<T>(_ value: T, for url: URL) {
		decodedCacheQueue.async(flags: .barrier) {
			self.decodedCache[url.absoluteString] = value
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
			URLSession.shared.dataTask(with: request) { data, response, error in
				let networkElapsed = CFAbsoluteTimeGetCurrent() - requestStartedAt

				if let error {
					completion(.failure(NBFetchServiceError.networkError(error)))
					return
				}

				let http = response as? HTTPURLResponse
				let responseData: Data
				let sourceLabel: String

				if http?.statusCode == 304, let cachedData {
					responseData = cachedData
					sourceLabel = "disk-cache/304"
				} else if let data {
					responseData = data
					sourceLabel = "network/\(http?.statusCode ?? 0)"
				} else {
					completion(.failure(NBFetchServiceError.noData))
					return
				}

				if http?.statusCode == 304,
				   let decoded: T = self.cachedDecodedValue(for: url, as: T.self) {
					NBRepositoryFetchDiagnostics.record(
						NBRepositoryFetchMetric(
							url: url.absoluteString,
							status: "decoded-cache/304",
							byteCount: responseData.count,
							networkSeconds: networkElapsed,
							decodeSeconds: 0,
							recordedAt: Date()
						)
					)
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
					self.storeDecodedValue(decodedData, for: url)

					if http?.statusCode != 304, let payloadURL {
						do {
							try responseData.write(to: payloadURL, options: .atomic)
							let defaults = UserDefaults.standard
							if let etag = http?.value(forHTTPHeaderField: "ETag") {
								defaults.set(
									etag,
									forKey: self.validatorKey("etag", url: url)
								)
							}
							if let modified = http?.value(forHTTPHeaderField: "Last-Modified") {
								defaults.set(
									modified,
									forKey: self.validatorKey("modified", url: url)
								)
							}
						} catch {
							print(
								"[Zag Store Sources] Cache write failed: " +
								"\(url.host ?? url.absoluteString) — " +
								error.localizedDescription
							)
						}
					}

					NBRepositoryFetchDiagnostics.record(
						NBRepositoryFetchMetric(
							url: url.absoluteString,
							status: sourceLabel,
							byteCount: responseData.count,
							networkSeconds: networkElapsed,
							decodeSeconds: decodeElapsed,
							recordedAt: Date()
						)
					)
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
					completion(.failure(NBFetchServiceError.parsingError(error)))
				}
			}.resume()
		}
	}
}

//
//  FetchService.swift
//  Loader
//
//  Created by samara on 14.03.2025.
//

import Foundation

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

	public init() {}

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

				let decodeStartedAt = CFAbsoluteTimeGetCurrent()
				do {
					let decodedData = try JSONDecoder().decode(T.self, from: responseData)
					let decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStartedAt

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

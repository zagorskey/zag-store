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
		cachedValue: T?,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		var request = URLRequest(url: url)
		let defaults = UserDefaults.standard
		let cacheKey = Data(url.absoluteString.utf8).base64EncodedString()

		if let etag = defaults.string(forKey: "NBFetchService.etag." + cacheKey) {
			request.setValue(etag, forHTTPHeaderField: "If-None-Match")
		}
		if let modified = defaults.string(forKey: "NBFetchService.modified." + cacheKey) {
			request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
		}

		URLSession.shared.dataTask(with: request) { data, response, error in
			if let error {
				completion(.failure(NBFetchServiceError.networkError(error)))
				return
			}

			if let http = response as? HTTPURLResponse, http.statusCode == 304,
			   let cachedValue {
				completion(.success(cachedValue))
				return
			}

			guard let data else {
				completion(.failure(NBFetchServiceError.noData))
				return
			}

			do {
				let decodedData = try JSONDecoder().decode(T.self, from: data)
				if let http = response as? HTTPURLResponse {
					if let etag = http.value(forHTTPHeaderField: "ETag") {
						defaults.set(etag, forKey: "NBFetchService.etag." + cacheKey)
					}
					if let modified = http.value(forHTTPHeaderField: "Last-Modified") {
						defaults.set(modified, forKey: "NBFetchService.modified." + cacheKey)
					}
				}
				completion(.success(decodedData))
			} catch {
				completion(.failure(NBFetchServiceError.parsingError(error)))
			}
		}.resume()
	}

	public func fetch<T: Decodable>(
		from url: URL,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		DispatchQueue.global(qos: .userInitiated).async {
			let task = URLSession.shared.dataTask(with: url) { data, response, error in
				if let error = error {
					completion(.failure(NBFetchServiceError.networkError(error)))
					return
				}
				
				guard let data = data else {
					completion(.failure(NBFetchServiceError.noData))
					return
				}
				
				do {
					let decoder = JSONDecoder()
					let decodedData = try decoder.decode(T.self, from: data)
					completion(.success(decodedData))
				} catch {
					completion(.failure(NBFetchServiceError.parsingError(error)))
				}
			}
			
			task.resume()
		}
	}
}

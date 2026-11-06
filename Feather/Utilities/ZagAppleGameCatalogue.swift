import Foundation

/// Which repository apps Apple's catalogue lists as games.
///
/// Many large repositories give only a name and bundle ID (no description or
/// category), so the Games page cannot tell their games from other apps. Apple's
/// public lookup takes up to 100 bundle IDs per request and returns each app's
/// primary genre and sub-genres. Results are saved on the device, so each
/// bundle ID is checked once (apps that are not games are checked again after
/// 30 days). Requests are paced to stay well inside Apple's rate limit, and a
/// run stops at the first error, carrying on the next time Games opens.
actor ZagAppleGameCatalogue {
	static let shared = ZagAppleGameCatalogue()

	private struct Entry: Codable {
		/// Apple's sub-genres for a game (for example "Puzzle"), or nil when
		/// the app is not a game or Apple does not list it.
		var genres: [String]?
		var checked: Date
	}

	static let batchSize = 100
	private static let pause: UInt64 = 3_500_000_000
	private static let recheckAfter: TimeInterval = 30 * 24 * 3600
	/// After this many batches with new games, the page is told.
	private static let progressEvery = 5

	private var entries: [String: Entry] = [:]
	private var loaded = false
	private var running = false
	private let session: URLSession

	private var fileURL: URL? {
		FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
			.appendingPathComponent("ZagAppleGameCatalogue.json")
	}

	init(session: URLSession = .shared) {
		self.session = session
	}

	/// Games Apple's catalogue has identified: lower-case bundle ID to its
	/// sub-genres.
	func knownGames() -> [String: [String]] {
		load()
		return entries.compactMapValues(\.genres)
	}

	/// Checks the bundle IDs not checked yet. `progress` receives the games
	/// known so far whenever new ones are found (every few batches, and at
	/// the end). Only one run at a time: a second call returns at once.
	func classify(
		_ bundleIDs: [String],
		progress: @escaping @Sendable ([String: [String]]) async -> Void
	) async {
		load()
		guard !running else { return }
		running = true
		defer { running = false }

		let now = Date()
		var seen = Set<String>()
		let pending = bundleIDs.compactMap { id -> String? in
			let key = id.lowercased()
			guard Self.isValid(key), seen.insert(key).inserted else { return nil }
			if let entry = entries[key],
			   entry.genres != nil || now.timeIntervalSince(entry.checked) < Self.recheckAfter {
				return nil
			}
			return key
		}
		guard !pending.isEmpty else { return }

		var batchesWithNewGames = 0
		for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
			guard !Task.isCancelled else { break }
			let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
			guard let games = await lookup(batch) else { break }

			let checked = Date()
			for key in batch {
				entries[key] = Entry(genres: games[key], checked: checked)
			}
			save()
			if !games.isEmpty { batchesWithNewGames += 1 }
			if batchesWithNewGames >= Self.progressEvery {
				batchesWithNewGames = 0
				await progress(entries.compactMapValues(\.genres))
			}
			try? await Task.sleep(nanoseconds: Self.pause)
		}
		if batchesWithNewGames > 0 {
			await progress(entries.compactMapValues(\.genres))
		}
	}

	/// The games in one batch, or nil if the request failed.
	private func lookup(_ batch: [String]) async -> [String: [String]]? {
		var components = URLComponents(string: "https://itunes.apple.com/lookup")
		components?.queryItems = [
			URLQueryItem(name: "bundleId", value: batch.joined(separator: ",")),
			URLQueryItem(name: "country", value: "us"),
			URLQueryItem(name: "entity", value: "software")
		]
		guard let url = components?.url else { return nil }
		var request = URLRequest(url: url)
		request.timeoutInterval = 20
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		guard let (data, response) = try? await session.data(for: request),
			  (response as? HTTPURLResponse)?.statusCode == 200,
			  data.count <= 4_000_000,
			  let decoded = try? JSONDecoder().decode(Lookup.self, from: data) else { return nil }

		let requested = Set(batch)
		var games: [String: [String]] = [:]
		for app in decoded.results where app.primaryGenreName == "Games" {
			guard let key = app.bundleId?.lowercased(), requested.contains(key) else { continue }
			games[key] = (app.genres ?? []).filter { $0 != "Games" }
		}
		return games
	}

	private struct Lookup: Decodable {
		struct App: Decodable {
			let bundleId: String?
			let primaryGenreName: String?
			let genres: [String]?
		}
		let results: [App]
	}

	/// A plausible App Store bundle ID (ASCII, dotted, not too long).
	private static func isValid(_ id: String) -> Bool {
		id.count <= 155 && id.contains(".") && !id.hasPrefix(".") &&
			id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
	}

	private func load() {
		guard !loaded else { return }
		loaded = true
		guard let fileURL, let data = try? Data(contentsOf: fileURL),
			  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
		entries = decoded
	}

	private func save() {
		guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
		try? data.write(to: fileURL, options: .atomic)
	}
}

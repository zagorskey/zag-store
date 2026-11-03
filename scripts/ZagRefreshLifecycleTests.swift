import Foundation

// Compiled with Feather/Utilities/ZagRepositoryIndexState.swift and
// Feather/Views/Library/ZagUpdateRowSnapshot.swift by
// scripts/test-zag-background-refresh.sh.

@main struct ZagRefreshLifecycleTests {
	static var failures = 0

	static func expect(_ condition: Bool, _ label: String) {
		print((condition ? "PASS  " : "FAIL  ") + label)
		if !condition { failures += 1 }
	}

	/// Drives ZagRepositoryIndexState with the events the Games page receives,
	/// in the order SourcesViewModel.fetchSources produces them:
	/// 1. `sources` is filtered to configured sources (isRefreshing false),
	/// 2. isRefreshing becomes true,
	/// 3. each finished repository publishes `sources` (isRefreshing true),
	/// 4. the completed snapshot publishes `sources` (isRefreshing true),
	/// 5. isRefreshing becomes false in `defer` (finished, failed or cancelled).
	/// A build finishes later; only accepted results become the visible index.
	struct GamesPage {
		var state = ZagRepositoryIndexState()
		var requested: [(generation: Int, repositories: [String: Int])] = []
		var visible: [String: Int]? = nil
		var isRefreshing = false
		var configured: [String]

		init(configured: [String]) { self.configured = configured }

		func signature(_ loaded: [String: Int]) -> String {
			configured.map { "\($0):\(loaded[$0] ?? -1)" }.joined(separator: "|")
		}

		mutating func publishSources(_ loaded: [String: Int]) {
			if let generation = state.repositoriesPublished(
				signature: signature(loaded),
				loadedRepositoryCount: loaded.count,
				isRefreshing: isRefreshing
			) { requested.append((generation, loaded)) }
		}

		mutating func setRefreshing(_ value: Bool, current loaded: [String: Int]) {
			isRefreshing = value
			guard !value else { return }
			if let generation = state.refreshEnded(
				signature: signature(loaded),
				loadedRepositoryCount: loaded.count
			) { requested.append((generation, loaded)) }
		}

		mutating func appear(_ loaded: [String: Int]) {
			if let generation = state.appeared(
				signature: signature(loaded),
				loadedRepositoryCount: loaded.count
			) { requested.append((generation, loaded)) }
		}

		/// Finishes builds in the given order (indices into `requested`).
		mutating func finishBuilds(_ order: [Int]? = nil) {
			for index in order ?? Array(requested.indices) {
				let build = requested[index]
				if state.accepts(generation: build.generation) { visible = build.repositories }
			}
		}

		/// One full refresh. `results` are repository app counts in finishing
		/// order; nil means that repository failed (its last snapshot is kept).
		mutating func refresh(
			from previous: [String: Int],
			results: [(String, Int?)],
			cancelledAfter: Int? = nil
		) -> [String: Int] {
			var loaded = previous.filter { configured.contains($0.key) }
			publishSources(loaded)
			setRefreshing(true, current: loaded)
			for (index, (name, count)) in results.enumerated() {
				if let cancelledAfter, index >= cancelledAfter { break }
				if let count { loaded[name] = count; publishSources(loaded) }
			}
			if cancelledAfter == nil { publishSources(loaded) }
			setRefreshing(false, current: loaded)
			return loaded
		}
	}

	static func indexTests() {
		let names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
		let full = Dictionary(uniqueKeysWithValues: names.map { ($0, 100) })

		// Cold launch: empty index, six repositories.
		var page = GamesPage(configured: names)
		page.appear([:])
		let loaded = page.refresh(from: [:], results: names.map { ($0, 100) })
		expect(page.requested.count <= 4,
			"cold launch: at most 4 builds for 6 repositories (was 6+), got \(page.requested.count)")
		expect(page.requested.contains { $0.repositories.count == 1 },
			"cold launch: the first finished repository is indexed at once")
		page.finishBuilds()
		expect(page.visible == full, "cold launch: the visible index is the complete final catalogue")
		expect(page.requested.last?.repositories == loaded, "cold launch: the last build uses the final snapshot")

		// Warm refresh: index exists; repositories publish one by one.
		var warm = page
		warm.requested.removeAll()
		_ = warm.refresh(from: loaded, results: names.map { ($0, 100) })
		expect(warm.requested.count == 1,
			"warm refresh: exactly one full rebuild, after the final repository (got \(warm.requested.count))")
		warm.finishBuilds()
		expect(warm.visible == full, "warm refresh: the complete catalogue is discoverable afterwards")

		// Same app counts, different content: the end-of-refresh rebuild is forced.
		var sameCounts = page
		sameCounts.requested.removeAll()
		_ = sameCounts.refresh(from: loaded, results: names.map { ($0, 100) })
		expect(sameCounts.requested.count == 1,
			"refresh with unchanged app counts still rebuilds once (index cannot go stale)")

		// A failed repository: last known-good snapshot is kept and indexed.
		var failing = page
		failing.requested.removeAll()
		var results = names.map { ($0, Optional(120)) }
		results[2].1 = nil
		let afterFailure = failing.refresh(from: loaded, results: results)
		failing.finishBuilds()
		expect(failing.requested.count == 1, "refresh with a failed repository: one rebuild")
		expect(failing.visible == afterFailure && afterFailure["gamma"] == 100 && afterFailure["alpha"] == 120,
			"refresh with a failed repository: new data indexed, failed repository keeps its last snapshot")

		// Cancelled after two repositories: the end still rebuilds from what loaded.
		var cancelled = page
		cancelled.requested.removeAll()
		let partial = cancelled.refresh(from: loaded, results: names.map { ($0, 150) }, cancelledAfter: 2)
		cancelled.finishBuilds()
		expect(cancelled.requested.count == 1, "cancelled refresh: one rebuild when it ends")
		expect(cancelled.visible == partial && partial["alpha"] == 150 && partial["gamma"] == 100,
			"cancelled refresh: index reflects the repositories that did refresh")

		// Back-to-back refreshes; the first build finishes after the second.
		var twice = page
		twice.requested.removeAll()
		let first = twice.refresh(from: loaded, results: names.map { ($0, 200) })
		let second = twice.refresh(from: first, results: names.map { ($0, 300) })
		expect(twice.requested.count == 2, "back-to-back refreshes: one rebuild each")
		twice.finishBuilds([1, 0])
		expect(twice.visible == second, "back-to-back refreshes: a late older build never replaces the newer index")

		// Outside a refresh, an unchanged publication or reappearance does nothing.
		var idle = page
		idle.requested.removeAll()
		idle.publishSources(loaded)
		idle.appear(loaded)
		expect(idle.requested.isEmpty, "unchanged publication or reappearance: no rebuild")
		var removed = loaded
		removed["zeta"] = nil
		idle.configured.removeLast()
		idle.publishSources(removed)
		expect(idle.requested.count == 1, "repository removed outside a refresh: one rebuild")

		// No repositories configured: an empty index is handled.
		var empty = GamesPage(configured: [])
		empty.appear([:])
		_ = empty.refresh(from: [:], results: [])
		empty.finishBuilds()
		expect(empty.visible == [:], "no repositories: empty index builds and is accepted")
	}

	static func row(_ id: String, version: String, notes: String = "Notes") -> ZagUpdateRowSnapshot {
		ZagUpdateRowSnapshot(
			id: id, bundleID: "com.example.\(id)", name: id.capitalized,
			iconURL: "https://example.com/\(id).png", sourceIconURL: nil,
			releaseDateText: nil, releaseNotes: notes, metadataText: "Version \(version)",
			version: version, build: nil, completedAt: nil
		)
	}

	static func persistenceTests() {
		let suite = "ZagRefreshLifecycleTests.\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suite) else {
			expect(false, "isolated UserDefaults suite"); return
		}
		defer { defaults.removePersistentDomain(forName: suite) }
		let key = ZagUpdateRowSnapshot.availableKey

		let a = [row("one", version: "1.1"), row("two", version: "2.0")]
		let b = [row("one", version: "1.2"), row("two", version: "2.0")]

		expect(ZagUpdateRowSnapshot.save(a, key: key, defaults: defaults), "first save writes")
		let stored = defaults.data(forKey: key)
		expect(!ZagUpdateRowSnapshot.save(a, key: key, defaults: defaults), "saving an unchanged snapshot does not write")
		expect(defaults.data(forKey: key) == stored, "unchanged snapshot leaves stored bytes untouched")
		let equalCopy = a.map { row($0.id, version: $0.version) }
		expect(!ZagUpdateRowSnapshot.save(equalCopy, key: key, defaults: defaults),
			"equal rows built separately encode to the same bytes (sorted keys)")

		// Two reconciliations in a row: each persists its own final result.
		expect(ZagUpdateRowSnapshot.save(b, key: key, defaults: defaults), "a newer reconciliation writes")
		expect(ZagUpdateRowSnapshot.load(key, defaults: defaults) == b, "the latest reconciliation is what is stored")

		// A completed, empty reconciliation must clear the cached rows.
		expect(ZagUpdateRowSnapshot.save([], key: key, defaults: defaults), "an empty result replaces cached rows")
		expect(ZagUpdateRowSnapshot.load(key, defaults: defaults).isEmpty, "the empty result is stored")

		// Snapshots written by older builds (unsorted keys) still load, and
		// re-saving them once normalises the encoding.
		let legacy = try! JSONEncoder().encode(b)
		defaults.set(legacy, forKey: key)
		expect(ZagUpdateRowSnapshot.load(key, defaults: defaults) == b, "older-build snapshots still load")
		_ = ZagUpdateRowSnapshot.save(b, key: key, defaults: defaults)
		expect(!ZagUpdateRowSnapshot.save(b, key: key, defaults: defaults), "after one normalising save, repeats do not write")

		// Popup closes and reopens: the appearance save is a no-op.
		let beforeReopen = defaults.data(forKey: key)
		expect(!ZagUpdateRowSnapshot.save(b, key: key, defaults: defaults) && defaults.data(forKey: key) == beforeReopen,
			"popup reappearance with unchanged updates does not rewrite storage")

		expect(ZagUpdateRowSnapshot.load("missing.key", defaults: defaults).isEmpty, "a missing key loads as no rows")
	}

	static func main() {
		indexTests()
		persistenceTests()
		if failures > 0 {
			print("\(failures) lifecycle test(s) failed")
			exit(1)
		}
		print("All refresh lifecycle tests passed")
	}
}

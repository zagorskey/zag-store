import Foundation

/// Decides when a derived index of the repository catalogue (the Games
/// search index) must be rebuilt, and which finished build may be shown.
///
/// The view feeds it the values that Combine publishes, so no decision
/// depends on notification ordering or on reading the model later.
///
/// Rules:
/// - While a refresh runs, every finished repository publishes. Once the
///   index contains at least one loaded repository, those publications are
///   skipped: the full rebuild would repeat once per repository.
/// - With no repository content indexed yet (first load), publications keep
///   building until one does, so the page is not empty during a long first
///   refresh.
/// - When a refresh ends (finished, failed or cancelled), the index is
///   always rebuilt once. A refresh can change apps without changing any
///   repository's app count, so the signature alone cannot prove the index
///   is current.
/// - Outside a refresh, a publication rebuilds only if the signature changed.
/// - Each build gets a generation; only the newest build's result is shown,
///   so an older build finishing late can never replace a newer index.
///
/// Pure and Foundation-only so host-side tests can compile it directly.
struct ZagRepositoryIndexState: Equatable {
	private(set) var signature = ""
	private(set) var generation = 0
	/// Loaded repositories in the newest requested build.
	private(set) var indexedRepositoryCount = 0

	var hasIndex: Bool { generation > 0 }

	/// A repository snapshot was published. Returns the generation to build,
	/// or nil when no rebuild is needed.
	mutating func repositoriesPublished(
		signature: String,
		loadedRepositoryCount: Int,
		isRefreshing: Bool
	) -> Int? {
		if isRefreshing && indexedRepositoryCount > 0 { return nil }
		return begin(signature: signature, loadedRepositoryCount: loadedRepositoryCount, force: false)
	}

	/// A refresh ended, whatever its outcome. Always rebuilds.
	mutating func refreshEnded(signature: String, loadedRepositoryCount: Int) -> Int? {
		begin(signature: signature, loadedRepositoryCount: loadedRepositoryCount, force: true)
	}

	/// Apple's catalogue identified more games. Always rebuilds.
	mutating func catalogueClassified(signature: String, loadedRepositoryCount: Int) -> Int? {
		begin(signature: signature, loadedRepositoryCount: loadedRepositoryCount, force: true)
	}

	/// The page appeared. Rebuilds only if the catalogue changed meanwhile.
	mutating func appeared(signature: String, loadedRepositoryCount: Int) -> Int? {
		begin(signature: signature, loadedRepositoryCount: loadedRepositoryCount, force: false)
	}

	/// True if a finished build may replace the visible index.
	func accepts(generation candidate: Int) -> Bool {
		candidate == generation
	}

	private mutating func begin(signature: String, loadedRepositoryCount: Int, force: Bool) -> Int? {
		guard force || !hasIndex || signature != self.signature else { return nil }
		self.signature = signature
		indexedRepositoryCount = loadedRepositoryCount
		generation += 1
		return generation
	}
}

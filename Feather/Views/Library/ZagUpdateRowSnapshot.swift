import Foundation

/// A persisted row of the Updates popup, shown on cold start until the first
/// reconciliation completes, and for Updated Recently.
///
/// Foundation-only so host-side tests can compile it directly.
struct ZagUpdateRowSnapshot: Codable, Identifiable, Equatable {
	let id: String
	let bundleID: String
	let name: String
	let iconURL: String?
	let sourceIconURL: String?
	let releaseDateText: String?
	let releaseNotes: String?
	let metadataText: String?
	let version: String
	// Optional for compatibility with snapshots saved by older Zag Store builds.
	let build: String?
	let completedAt: Date?

	static let availableKey = "ZagStore.availableUpdateRows"
	static let recentKey = "ZagStore.updatedRecentlyRows"

	static func load(_ key: String, defaults: UserDefaults = .standard) -> [Self] {
		guard let data = defaults.data(forKey: key),
			  let rows = try? JSONDecoder().decode([Self].self, from: data)
		else { return [] }
		return rows
	}

	/// Saves the rows unless the stored bytes are already identical, so
	/// repeated saves of an unchanged snapshot do not rewrite UserDefaults.
	/// Keys are sorted so equal rows always encode to equal bytes; the JSON
	/// remains readable by older builds. Returns true if it wrote.
	@discardableResult
	static func save(_ rows: [Self], key: String, defaults: UserDefaults = .standard) -> Bool {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		guard let data = try? encoder.encode(rows) else { return false }
		if defaults.data(forKey: key) == data { return false }
		defaults.set(data, forKey: key)
		return true
	}
}

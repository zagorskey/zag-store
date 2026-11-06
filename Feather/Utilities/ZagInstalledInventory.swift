import Foundation

// Installed-app state for update reconciliation.
//
// The iPhone's installed apps are read over RPPairing. That read fails while
// Mobile Data is on (the iPhone refuses RPPairing then), and it has not run
// yet at cold start. Reconciliation used to fall back to Zag Store's Signed
// records whenever the live list was not loaded. Signed records only cover
// apps Zag Store signed and still holds, so every other installed app
// silently dropped out of the update set (13 updates on Wi-Fi, 6 on Mobile
// Data). The last successfully read list is now kept and used instead, and
// the report says which one was used.
//
// Foundation only, so it is tested on the host.

/// One installed app as read from the iPhone.
struct ZagInventoryEntry: Codable, Equatable {
	let bundleID: String
	let version: String
	let build: String
	let name: String
}

/// A complete installed-app list and when it was read.
struct ZagInventorySnapshot: Codable, Equatable {
	let readAt: Date
	let apps: [String: ZagInventoryEntry]
}

/// Where reconciliation's installed-app state came from.
enum ZagInventorySource: Equatable {
	/// Read from the iPhone in this session.
	case live
	/// The last list read from the iPhone, kept because a live read is
	/// unavailable (Mobile Data, cold start, or a failed read).
	case cached(readAt: Date)
	/// No device list exists; Zag Store's Signed records stand in.
	case signedFallback(reason: String)

	func label(now: Date = Date()) -> String {
		switch self {
		case .live:
			return "live device inventory"
		case .cached(let readAt):
			let age = max(0, Int(now.timeIntervalSince(readAt) / 60))
			return "last device inventory, read \(age) min ago (live read unavailable)"
		case .signedFallback(let reason):
			return "Signed fallback (\(reason))"
		}
	}
}

struct ZagInventoryResolution: Equatable {
	let source: ZagInventorySource
	let apps: [String: ZagInventoryEntry]

	/// The installed state came from the iPhone itself, live or kept.
	var isDeviceInventory: Bool {
		if case .signedFallback = source { return false }
		return true
	}
}

enum ZagInventoryResolver {
	/// Chooses the installed-app state for one reconciliation. The same
	/// device list gives the same result whatever the network or the entry
	/// point (cold start, manual refresh, background refresh, Apps page).
	static func resolve(
		liveLoaded: Bool,
		live: [String: ZagInventoryEntry],
		cached: ZagInventorySnapshot?,
		pairingFilePresent: Bool
	) -> ZagInventoryResolution {
		guard pairingFilePresent else {
			return ZagInventoryResolution(source: .signedFallback(reason: "not paired"), apps: [:])
		}
		if liveLoaded {
			return ZagInventoryResolution(source: .live, apps: live)
		}
		if let cached, !cached.apps.isEmpty {
			return ZagInventoryResolution(source: .cached(readAt: cached.readAt), apps: cached.apps)
		}
		return ZagInventoryResolution(
			source: .signedFallback(reason: "device inventory unavailable and none saved yet"),
			apps: [:]
		)
	}
}

/// Keeps the last complete installed-app list across launches. It holds
/// bundle IDs, versions and names only.
final class ZagInventorySnapshotStore {
	static let shared = ZagInventorySnapshotStore(
		fileURL: FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("ZagStore-InstalledInventory.json")
	)

	private let fileURL: URL?
	private let lock = NSLock()
	private var memo: ZagInventorySnapshot??

	init(fileURL: URL?) {
		self.fileURL = fileURL
	}

	func load() -> ZagInventorySnapshot? {
		lock.lock(); defer { lock.unlock() }
		if let memo { return memo }
		let snapshot = fileURL
			.flatMap { try? Data(contentsOf: $0) }
			.flatMap { try? JSONDecoder().decode(ZagInventorySnapshot.self, from: $0) }
		memo = .some(snapshot)
		return snapshot
	}

	/// Saves a list read successfully from the iPhone. An empty list is
	/// not saved: it would make every installed app look absent.
	func save(_ snapshot: ZagInventorySnapshot) {
		guard !snapshot.apps.isEmpty else { return }
		lock.lock(); defer { lock.unlock() }
		memo = .some(snapshot)
		guard let fileURL else { return }
		try? FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		if let data = try? JSONEncoder().encode(snapshot) {
			try? data.write(to: fileURL, options: .atomic)
		}
	}

	func clear() {
		lock.lock(); defer { lock.unlock() }
		memo = .some(nil)
		if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
	}
}

import Combine
import Foundation

/// Saves every installed-app list read successfully from the iPhone, so
/// update reconciliation can keep using it while a live read is unavailable
/// (Mobile Data, the next cold start). It only observes the RPPairing core's
/// published state; the core itself is unchanged.
@MainActor
final class ZagInventorySnapshotRecorder {
	static let shared = ZagInventorySnapshotRecorder()

	private var cancellable: AnyCancellable?

	func start() {
		guard cancellable == nil else { return }
		let core = ZagRPPairingCore.shared
		// The core assigns `installedApps` before it publishes `.loaded`,
		// so the list read here is the one that just completed.
		cancellable = core.$installedAppsState.sink { state in
			guard case .loaded = state else { return }
			ZagInventorySnapshotStore.shared.save(
				ZagInventorySnapshot(readAt: Date(), apps: core.inventoryEntries)
			)
		}
	}
}

extension ZagRPPairingCore {
	/// The live installed-app list in the form reconciliation uses.
	var inventoryEntries: [String: ZagInventoryEntry] {
		installedApps.mapValues {
			ZagInventoryEntry(bundleID: $0.bundleID, version: $0.version, build: $0.build, name: $0.name)
		}
	}
}

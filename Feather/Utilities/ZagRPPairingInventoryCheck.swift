import Foundation

// Reads the device's installed apps over RPPairing until an expected change
// shows up, bounded. Used while Mobile Data Fix still has Mobile Data off:
// after `on`, the iPhone refuses RPPairing again and the list can't be read.
// Foundation only, with every dependency injected, so it is tested on the host.

@MainActor
struct ZagRPPairingInventoryCheck {
	struct Environment {
		var transportBusy: () -> Bool
		/// A fresh read of the device's installed bundle IDs over RPPairing.
		var installedApps: () async -> Result<Set<String>, Error>
		var sleep: (TimeInterval) async -> Void
		var now: () -> Date
		var log: (String) -> Void
	}

	struct Outcome: Equatable {
		/// The newest list read, if any read succeeded.
		var list: Set<String>?
		/// The list showed the expected state.
		var confirmed: Bool
	}

	/// Total wait for the transport, checked every half second.
	static let transportWait: TimeInterval = 20
	static let transportPoll: TimeInterval = 0.5
	/// Waits before each read (about 6 s in total).
	static let delays: [TimeInterval] = [0, 1, 2, 3]

	let env: Environment

	/// Reads until `bundleID` is present (`expectInstalled`) or absent. With
	/// no bundle ID, one successful read is enough.
	func run(bundleID: String?, expectInstalled: Bool, label: String, start: Date) async -> Outcome {
		func elapsed() -> String { String(format: "+%.1f s", env.now().timeIntervalSince(start)) }

		var waited: TimeInterval = 0
		while env.transportBusy() {
			guard waited < Self.transportWait else {
				env.log("\(label): connection still busy; device list not read")
				return Outcome(list: nil, confirmed: false)
			}
			await env.sleep(Self.transportPoll)
			waited += Self.transportPoll
		}

		var latest: Set<String>?
		for (index, delay) in Self.delays.enumerated() {
			if delay > 0 { await env.sleep(delay) }
			switch await env.installedApps() {
			case .success(let installed):
				latest = installed
				guard let bundleID else {
					env.log("\(label) \(index + 1): device list read (\(elapsed()))")
					return Outcome(list: installed, confirmed: true)
				}
				if installed.contains(bundleID) == expectInstalled {
					env.log("\(label) \(index + 1): app \(expectInstalled ? "present in" : "absent from") device list (\(elapsed()))")
					return Outcome(list: installed, confirmed: true)
				}
				env.log("\(label) \(index + 1): app \(expectInstalled ? "not yet listed" : "still listed") (\(elapsed()))")
			case .failure(let error):
				env.log("\(label) \(index + 1): device list unavailable (\(elapsed())): \(error.localizedDescription)")
			}
		}
		return Outcome(list: latest, confirmed: false)
	}
}

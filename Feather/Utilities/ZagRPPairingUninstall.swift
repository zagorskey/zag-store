import Foundation

// Removes an app over RPPairing while Mobile Data Fix has Mobile Data off,
// and confirms the removal before Mobile Data comes back on.
//
// It runs as the coordinator's operation body, so the flow sends `on` only
// after this returns or throws. Foundation only, with every dependency
// injected, so each path is tested on the host.
//
// Steps:
// 1. Wait (bounded) for the single RPPairing transport to be free. Returning
//    from Shortcuts makes Library and app-detail screens refresh the device's
//    app list, which holds that transport for a few seconds.
// 2. Submit the uninstall once. installation_proxy reports completion only
//    after iOS has finished; that reply is required.
// 3. Read the device's app list again (fresh, over RPPairing) until the
//    bundle ID is gone, bounded. Still listed at the end is a failure.
//    If the list can't be read at all, the installation service's
//    completion stands as the confirmation, and the log says so.

enum ZagRPPairingUninstallFailure: LocalizedError, Equatable {
	/// Another RPPairing operation kept the connection for the whole wait.
	case connectionBusy
	/// The uninstall request failed or the connection was lost.
	case requestFailed(String)
	/// iOS reported completion but still lists the app.
	case stillInstalled
	case cancelled

	var errorDescription: String? {
		switch self {
		case .connectionBusy:
			return "Zag Store's device connection stayed busy, so the app was not removed. Try again in a moment."
		case .requestFailed(let message):
			return "The app was not removed. \(message)"
		case .stillInstalled:
			return "iOS accepted the removal request, but the app is still installed."
		case .cancelled:
			return "Cancelled. The app was not removed."
		}
	}
}

enum ZagRPPairingUninstallConfirmation: Equatable {
	/// The device's app list no longer contains the app.
	case verified
	/// installation_proxy completed, but the app list could not be read.
	case serviceCompleted
}

@MainActor
struct ZagRPPairingUninstall {
	struct Environment {
		var transportBusy: () -> Bool
		/// Submits the uninstall; returns when the installation service replies.
		var uninstall: (String) async -> Result<Void, Error>
		/// A fresh read of the device's installed bundle IDs over RPPairing.
		var installedApps: () async -> Result<Set<String>, Error>
		var sleep: (TimeInterval) async -> Void
		var now: () -> Date
		var log: (String) -> Void
	}

	/// Total wait for the transport, checked every half second.
	static let transportWait: TimeInterval = 20
	static let transportPoll: TimeInterval = 0.5
	/// Waits before each verification read (about 6 s in total).
	static let verifyDelays: [TimeInterval] = [0, 1, 2, 3]

	let env: Environment

	func run(bundleID: String) async throws -> ZagRPPairingUninstallConfirmation {
		let start = env.now()
		func elapsed() -> String { String(format: "+%.1f s", env.now().timeIntervalSince(start)) }

		var waited: TimeInterval = 0
		while env.transportBusy() {
			if Task.isCancelled { throw cancelled(elapsed()) }
			guard waited < Self.transportWait else {
				env.log("Uninstall: connection still busy after \(Int(waited)) s; not submitted")
				throw ZagRPPairingUninstallFailure.connectionBusy
			}
			await env.sleep(Self.transportPoll)
			waited += Self.transportPoll
		}
		if waited > 0 { env.log("Uninstall: connection free after \(String(format: "%.1f", waited)) s") }
		if Task.isCancelled { throw cancelled(elapsed()) }

		env.log("Uninstall: request submitted for \(bundleID) (\(elapsed()))")
		switch await env.uninstall(bundleID) {
		case .success:
			// Completion means pair-verify, the tunnel and installation_proxy
			// all worked, and iOS finished the removal.
			env.log("Uninstall: service reported completion (\(elapsed()))")
		case .failure(let error):
			let message = error.localizedDescription
			env.log("Uninstall: service reported failure (\(elapsed())): \(message)")
			throw ZagRPPairingUninstallFailure.requestFailed(message)
		}

		var listRead = false
		for (index, delay) in Self.verifyDelays.enumerated() {
			if delay > 0 { await env.sleep(delay) }
			switch await env.installedApps() {
			case .success(let installed):
				listRead = true
				if !installed.contains(bundleID) {
					env.log("Verify \(index + 1): app absent from device list (\(elapsed())); removal confirmed")
					return .verified
				}
				env.log("Verify \(index + 1): app still listed (\(elapsed()))")
			case .failure(let error):
				env.log("Verify \(index + 1): device list unavailable (\(elapsed())): \(error.localizedDescription)")
			}
		}
		if listRead {
			env.log("Uninstall: app still listed after verification; reporting failure")
			throw ZagRPPairingUninstallFailure.stillInstalled
		}
		env.log("Uninstall: device list unreadable; installation service completion is the confirmation")
		return .serviceCompleted
	}

	private func cancelled(_ at: String) -> ZagRPPairingUninstallFailure {
		env.log("Uninstall: cancelled before submission (\(at))")
		return .cancelled
	}
}

import Foundation

/// One callback from the native Gate4 installer (zag_gate4_install).
struct ZagGate4Event: Equatable {
	let code: Int32
	let message: String
}

/// Decides whether a failed self-update attempt may release its pending
/// installation record so the user can safely try again.
///
/// The pending record only prevents overlapping installs and lets the next
/// launch verify the replacement by executable hash. It is separate from the
/// signed-metadata rollback store, so releasing it never lowers an accepted
/// sequence or permits a downgrade.
///
/// The record is released automatically only when the callbacks prove the
/// Upgrade request was never sent. Anything unknown, missing, reordered or
/// late keeps it; the user can still clear it after confirming.
enum ZagSelfUpdateRetryPolicy {
	enum InstallerProgress: Equatable {
		/// The native installer was never started.
		case notStarted
		/// The installer reported failure, and every callback before it shows
		/// that it stopped before the Upgrade request could be sent.
		case failedBeforeUpgradeRequest
		/// Anything else. The Upgrade request may have reached iOS.
		case ambiguous
	}

	/// Release the record only when iOS cannot be replacing the app.
	static func mayReleasePendingRecord(after progress: InstallerProgress) -> Bool {
		switch progress {
		case .notStarted, .failedBeforeUpgradeRequest: return true
		case .ambiguous: return false
		}
	}

	/// Connection stages emitted in this order before anything is uploaded
	/// or installed: starting, pair verified, tunnel, RSD.
	static let connectionStages: [Int32] = [201, 202, 203, 204]

	/// The 205 message for the only path that uploads in a separate step
	/// (208 progress, then 209) before sending Upgrade. Every other bundle ID
	/// uses a helper that uploads and sends Upgrade in one call with no
	/// callback in between, so a failure after its 205 is ambiguous.
	/// Must match run_gate4_install in RPPairingCore/rust-core/src/lib.rs.
	static let streamedSelfUpdateAnnouncement = "Upgrading com.cwd43.gu29"

	/// Classify a failed attempt from its callbacks, captured when it ended.
	/// Pass nil when no terminal callback was captured.
	static func progress(afterEvents events: [ZagGate4Event]?) -> InstallerProgress {
		// The attempt must have ended in failure. Every earlier event must
		// match the expected sequence below, so a second failure, an unknown
		// code or a late callback anywhere makes the attempt ambiguous.
		guard let events, let last = events.last, last.code == -4 else { return .ambiguous }
		let before = events.dropLast()

		// Connection stages must start at 201 and arrive in order, once each.
		var index = before.startIndex
		var stage = 0
		while index < before.endIndex, stage < connectionStages.count,
		      before[index].code == connectionStages[stage] {
			index += 1
			stage += 1
		}
		guard stage > 0 else { return .ambiguous }
		// Failed while connecting: nothing was uploaded or installed.
		if index == before.endIndex { return .failedBeforeUpgradeRequest }

		// After connecting, only the streamed self-update path can be proven
		// safe, and only while it is still uploading (208, before 209).
		guard stage == connectionStages.count,
		      before[index].code == 205,
		      before[index].message == streamedSelfUpdateAnnouncement else { return .ambiguous }
		var previousPercent = 0
		for event in before[(index + 1)...] {
			guard event.code == 208,
			      let percent = Int(event.message),
			      percent > previousPercent, percent <= 100 else { return .ambiguous }
			previousPercent = percent
		}
		return .failedBeforeUpgradeRequest
	}
}

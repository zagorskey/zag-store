import Foundation

/// Decides whether a failed self-update attempt may release its pending
/// installation record so the user can safely try again.
///
/// The pending record only prevents overlapping installs and lets the next
/// launch verify the replacement by executable hash. It is separate from the
/// signed-metadata rollback store, so releasing it never lowers an accepted
/// sequence or permits a downgrade.
enum ZagSelfUpdateRetryPolicy {
	/// How far the native installer got before it reported failure.
	enum InstallerProgress: Equatable {
		/// The installer never started (busy, could not start, staging copy failed).
		case notStarted
		/// The IPA was still being uploaded; the Upgrade request was not sent.
		case uploadOnly
		/// The IPA was fully staged or iOS reported install progress, so the
		/// Upgrade request may have reached the device.
		case upgradeMayHaveBeenSubmitted
	}

	/// Release the record only when iOS cannot be replacing the app.
	/// Otherwise keep it so the next launch can verify what happened.
	static func mayReleasePendingRecord(after progress: InstallerProgress) -> Bool {
		switch progress {
		case .notStarted, .uploadOnly: return true
		case .upgradeMayHaveBeenSubmitted: return false
		}
	}

	/// Map a Gate4 callback code to installer progress. Codes follow
	/// zag_gate4_install: 208 upload, 209 fully staged, 206 iOS progress,
	/// 210 upgrade transmitted, 207 complete.
	static func progress(afterCallbackCodes codes: [Int32]) -> InstallerProgress {
		if codes.contains(where: { [209, 206, 210, 207].contains($0) }) {
			return .upgradeMayHaveBeenSubmitted
		}
		return codes.isEmpty ? .notStarted : .uploadOnly
	}
}

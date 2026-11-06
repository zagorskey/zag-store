import Foundation
import Combine

// One shared state per installation job, independent of any row's view
// lifecycle, so scrolling, Shortcuts handoffs and foreground/background
// transitions keep the stage and progress. Foundation only, so the rules are
// tested on the host.
//
// Cancellation rules:
// - Download stages (downloading, paused, resuming): cancel now.
// - Importing, signing, packaging, preparing Mobile Data Fix: the current
//   step can't be interrupted, so the request is honoured at the next safe
//   point. Records a finished step committed (Imported, Signed) are kept.
// - Installing and restoring Mobile Data: not cancellable. The RPPairing
//   worker has no cancel signal, and iOS may already be installing.

enum ZagInstallStage: Equatable {
	case downloading
	case paused
	case resuming
	case importing
	case signing
	case packaging
	case preparingMobileDataFix
	case installing
	case restoringMobileData
	case completed
	case cancelled
	case failed

	var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
	var isDownload: Bool { self == .downloading || self == .paused || self == .resuming }

	/// Cancel takes effect immediately.
	var cancelsImmediately: Bool { isDownload }
	/// Cancel waits for the current step, then stops before the next one.
	var cancelsAtSafePoint: Bool {
		switch self {
		case .importing, .signing, .packaging, .preparingMobileDataFix: return true
		default: return false
		}
	}
	var allowsCancel: Bool { cancelsImmediately || cancelsAtSafePoint }
	/// RPPairing owns the device now; the job can only finish.
	var isFinishing: Bool { self == .installing || self == .restoringMobileData }
}

enum ZagInstallCancelResponse: Equatable {
	/// Stop the transfer now.
	case now
	/// Recorded; the job stops at its next safe point.
	case afterCurrentStep
	/// Installation has begun and must finish.
	case notPossible
	case noJob
}

/// Thrown at a safe point after the user cancelled.
struct ZagInstallCancelled: LocalizedError, Equatable {
	var errorDescription: String? { "Installation cancelled." }
}

struct ZagInstallJob: Equatable {
	let id: String
	var stage: ZagInstallStage
	/// Download progress while downloading; install progress while installing.
	var progress: Double = 0
	/// The server supports genuine resume (Range plus a validator).
	var canPause = false
	var cancelRequested = false
	/// False for jobs that end without installing (sign only).
	var offersCancel = true
}

@MainActor
final class ZagInstallJobs: ObservableObject {
	static let shared = ZagInstallJobs()

	@Published private(set) var jobs: [String: ZagInstallJob] = [:]

	init() {}

	func job(_ id: String) -> ZagInstallJob? { jobs[id] }
	func isActive(_ id: String) -> Bool { jobs[id] != nil }
	func isCancelRequested(_ id: String) -> Bool { jobs[id]?.cancelRequested == true }

	/// Starts a job. Refuses a second job with the same ID, so repeated taps
	/// never start duplicate work.
	@discardableResult
	func begin(_ id: String, stage: ZagInstallStage, offersCancel: Bool = true) -> Bool {
		guard jobs[id] == nil else { return false }
		jobs[id] = ZagInstallJob(id: id, stage: stage, offersCancel: offersCancel)
		return true
	}

	func advance(_ id: String, to stage: ZagInstallStage) {
		guard var job = jobs[id], !job.stage.isTerminal, job.stage != stage else { return }
		// Finishing stages never go back to a cancellable one.
		if job.stage.isFinishing, stage.allowsCancel { return }
		if !stage.isDownload { job.canPause = false }
		// Install progress starts at zero; download progress is kept across
		// pause and resume.
		if stage == .installing { job.progress = 0 }
		job.stage = stage
		jobs[id] = job
	}

	/// Download progress never moves backwards while transferring, so a
	/// resume never looks like a restart.
	func setProgress(_ id: String, _ value: Double) {
		guard var job = jobs[id] else { return }
		let clamped = min(1, max(0, value))
		if job.stage.isDownload, clamped < job.progress { return }
		// Every visible row observes the store, so publish in small steps
		// rather than on every network chunk.
		guard abs(clamped - job.progress) >= 0.005 || (clamped == 1 && job.progress != 1) else { return }
		job.progress = clamped
		jobs[id] = job
	}

	func setCanPause(_ id: String, _ canPause: Bool) {
		guard var job = jobs[id], job.stage.isDownload, job.canPause != canPause else { return }
		job.canPause = canPause
		jobs[id] = job
	}

	func requestCancel(_ id: String) -> ZagInstallCancelResponse {
		guard var job = jobs[id] else { return .noJob }
		guard job.offersCancel, job.stage.allowsCancel else { return .notPossible }
		job.cancelRequested = true
		jobs[id] = job
		return job.stage.cancelsImmediately ? .now : .afterCurrentStep
	}

	/// A safe point: throws if the user cancelled.
	func checkpoint(_ id: String) throws {
		if isCancelRequested(id) { throw ZagInstallCancelled() }
	}

	/// The last safe point. After this, the job can only finish.
	func beginInstalling(_ id: String) throws {
		try checkpoint(id)
		advance(id, to: .installing)
	}

	func finish(_ id: String) {
		jobs[id] = nil
	}
}

// MARK: - Resumable downloads

enum ZagResumableDownload {
	/// A download can be paused and genuinely resumed only when the server
	/// accepts byte ranges and identifies the file (ETag or Last-Modified),
	/// so a resume continues the same file.
	static func supportsResume(statusCode: Int, header: (String) -> String?, expectedLength: Int64) -> Bool {
		guard statusCode == 200 || statusCode == 206, expectedLength > 0 else { return false }
		guard let ranges = header("Accept-Ranges"), ranges.lowercased().contains("bytes") else { return false }
		let etag = header("ETag").map { !$0.isEmpty } ?? false
		let modified = header("Last-Modified").map { !$0.isEmpty } ?? false
		return etag || modified
	}

	enum ResumeCheck: Equatable {
		case continued
		/// The server sent the file from the start; this is not a resume.
		case restartedByServer
	}

	static func check(resumedAtOffset offset: Int64, bytesBeforePause: Int64) -> ResumeCheck {
		(offset == 0 && bytesBeforePause > 0) ? .restartedByServer : .continued
	}

	/// The partial-download file referenced by URLSession resume data, if
	/// any. Only CFNetwork's own temporary files are returned.
	static func partialFileName(inResumeData data: Data) -> String? {
		guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
		var found: String?
		func visit(_ value: Any) {
			guard found == nil else { return }
			if let string = value as? String {
				let name = (string as NSString).lastPathComponent
				if name.hasPrefix("CFNetworkDownload_"), name.hasSuffix(".tmp") { found = name }
			} else if let dictionary = value as? [String: Any] {
				dictionary.values.forEach(visit)
			} else if let array = value as? [Any] {
				array.forEach(visit)
			}
		}
		visit(plist)
		return found
	}
}

enum ZagDownloadPauseError: LocalizedError, Equatable {
	/// Pausing stopped the transfer, but no resume data was produced.
	case notResumable
	/// On resume the server sent the whole file again.
	case serverRestarted

	var errorDescription: String? {
		switch self {
		case .notResumable:
			return "The download stopped and can't be continued. Tap Retry to download it again."
		case .serverRestarted:
			return "The server couldn't continue the paused download. Tap Retry to download it again from the start."
		}
	}
}

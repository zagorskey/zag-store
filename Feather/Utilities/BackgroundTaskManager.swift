//
//  BackgroundTaskManager.swift
//  Feather
//
//  Created by Nagata Asami on 4/1/26.
//

#if !targetEnvironment(macCatalyst)

import Foundation
import BackgroundTasks
import CryptoKit

@available(iOS 26.0, *)
class BackgroundTaskManager: ObservableObject {
	static let shared = BackgroundTaskManager()

	// Only identifiers matching a permitted Info.plist wildcard may be registered.
	private let identifierPrefix = ZagBackgroundTaskIdentifiers.continuedDownloadPrefix()

	// Completes every task exactly once and never registers an identifier twice.
	private let ledger = ZagContinuedTaskLedger()

	private func identifier(for downloadId: String) -> String? {
		identifierPrefix.map { $0 + downloadId.md5 }
	}

	func startTask(for download: Download) {
		guard let transfer = download.task else { return }
		guard let taskIdentifier = identifier(for: download.id) else {
			ZagLogger.shared.warning("Downloads", "No permitted continued-processing identifier; downloading in the foreground only")
			return
		}

		if !ledger.isRegistered(taskIdentifier) {
			let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
				guard let self, let task = task as? BGContinuedProcessingTask else {
					task.setTaskCompleted(success: false)
					return
				}
				self.launch(task)
			}
			guard registered else {
				ZagLogger.shared.warning("Downloads", "Continued-processing task registration was refused")
				return
			}
			ledger.markRegistered(taskIdentifier)
		}

		ledger.willSubmit(taskIdentifier, transfer: transfer)
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: download.fileName, subtitle: .localized("Downloading"))
		request.strategy = .queue
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			ledger.submitFailed(taskIdentifier, transfer: transfer)
			ZagLogger.shared.warning("Downloads", "Continued-processing task was not submitted: \(error.localizedDescription)")
		}
	}

	private func launch(_ task: BGContinuedProcessingTask) {
		let taskIdentifier = task.identifier
		// If the download already ended, the ledger completes the task now.
		guard let token = ledger.didLaunch(taskIdentifier, task: task, complete: { success in
			task.setTaskCompleted(success: success)
		}) else { return }

		task.expirationHandler = { [weak self] in
			// Cancel only the transfer this task was submitted for. By the
			// time the main queue runs, the identifier may belong to a
			// replacement or retried download, which must keep running.
			guard let self, let expiredTransfer = self.ledger.expire(taskIdentifier, token: token) else { return }
			DispatchQueue.main.async {
				let manager = DownloadManager.shared
				if let download = ZagContinuedTaskLedger.download(using: expiredTransfer, in: manager.downloads, transfer: { $0.task }) {
					manager.cancelDownload(download)
				}
			}
		}
	}

	func updateProgress(for download: Download, progress: Double) {
		guard let transfer = download.task,
		      let taskIdentifier = identifier(for: download.id),
		      let task = ledger.runningTask(taskIdentifier, transfer: transfer) as? BGContinuedProcessingTask else { return }
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(progress * 100)

		task.updateTitle(task.title, subtitle: "\(Int(progress * 100))%")
	}

	/// Ends the background task for a download that finished, failed or was
	/// cancelled. Safe to call more than once. Only ends the task submitted
	/// for this download's current transfer.
	func stopTask(for download: Download, success: Bool) {
		guard let transfer = download.task,
		      let taskIdentifier = identifier(for: download.id) else { return }
		if ledger.finish(taskIdentifier, transfer: transfer, success: success) == .cancelQueuedRequest {
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
		}
	}
}

extension String {
	var md5: String {
		Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
	}
}

#endif

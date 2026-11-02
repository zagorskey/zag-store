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

	func startTask(for downloadId: String, filename: String) {
		guard let taskIdentifier = identifier(for: downloadId) else {
			ZagLogger.shared.warning("Downloads", "No permitted continued-processing identifier; downloading in the foreground only")
			return
		}

		if !ledger.isRegistered(taskIdentifier) {
			let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
				guard let self, let task = task as? BGContinuedProcessingTask else {
					task.setTaskCompleted(success: false)
					return
				}
				self.launch(task, downloadId: downloadId)
			}
			guard registered else {
				ZagLogger.shared.warning("Downloads", "Continued-processing task registration was refused")
				return
			}
			ledger.markRegistered(taskIdentifier)
		}

		ledger.willSubmit(taskIdentifier)
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: filename, subtitle: .localized("Downloading"))
		request.strategy = .queue
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			ledger.submitFailed(taskIdentifier)
			ZagLogger.shared.warning("Downloads", "Continued-processing task was not submitted: \(error.localizedDescription)")
		}
	}

	private func launch(_ task: BGContinuedProcessingTask, downloadId: String) {
		let taskIdentifier = task.identifier
		// If the download already ended, the ledger completes the task now.
		guard let token = ledger.didLaunch(taskIdentifier, task: task, complete: { success in
			task.setTaskCompleted(success: success)
		}) else { return }

		task.expirationHandler = { [weak self] in
			guard let self, self.ledger.expire(taskIdentifier, token: token) else { return }
			DispatchQueue.main.async {
				if let download = DownloadManager.shared.getDownload(by: downloadId) {
					DownloadManager.shared.cancelDownload(download)
				}
			}
		}
	}

	func updateProgress(for downloadId: String, progress: Double) {
		guard let taskIdentifier = identifier(for: downloadId),
		      let task = ledger.runningTask(taskIdentifier) as? BGContinuedProcessingTask else { return }
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(progress * 100)

		task.updateTitle(task.title, subtitle: "\(Int(progress * 100))%")
	}

	/// Ends the background task for a download that finished, failed or was
	/// cancelled. Safe to call more than once.
	func stopTask(for downloadId: String, success: Bool) {
		guard let taskIdentifier = identifier(for: downloadId) else { return }
		if ledger.finish(taskIdentifier, success: success) == .cancelQueuedRequest {
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

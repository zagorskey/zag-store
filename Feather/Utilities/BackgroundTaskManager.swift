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

	private var activeTasks: [String: BGContinuedProcessingTask] = [:]
	private var registeredTasks: Set<String> = []

	private func identifier(for downloadId: String) -> String? {
		identifierPrefix.map { $0 + downloadId.md5 }
	}

	func startTask(for downloadId: String, filename: String) {
		guard let taskIdentifier = identifier(for: downloadId) else {
			ZagLogger.shared.warning("Downloads", "No permitted continued-processing identifier; downloading in the foreground only")
			return
		}

		if !registeredTasks.contains(taskIdentifier) {
			let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
				guard let task = task as? BGContinuedProcessingTask else { return }
				self.activeTasks[task.identifier] = task
				
				task.expirationHandler = {
					if let download = DownloadManager.shared.getDownload(by: downloadId) {
						DownloadManager.shared.cancelDownload(download)
					}
					self.activeTasks.removeValue(forKey: task.identifier)
				}
			}
			guard registered else {
				ZagLogger.shared.warning("Downloads", "Continued-processing task registration was refused")
				return
			}
			self.registeredTasks.insert(taskIdentifier)
		}

		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: filename, subtitle: .localized("Downloading"))
		request.strategy = .queue
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			ZagLogger.shared.warning("Downloads", "Continued-processing task was not submitted: \(error.localizedDescription)")
		}
	}
	
	func updateProgress(for downloadId: String, progress: Double) {
		guard let taskIdentifier = identifier(for: downloadId),
		      let task = activeTasks[taskIdentifier] else { return }
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(progress * 100)
		
		task.updateTitle(task.title, subtitle: "\(Int(progress * 100))%")
		
		if task.progress.completedUnitCount == task.progress.totalUnitCount {
			stopTask(for: downloadId, success: true)
		}
	}
	
	func stopTask(for downloadId: String, success: Bool) {
		guard let taskIdentifier = identifier(for: downloadId),
		      let task = activeTasks[taskIdentifier] else { return }
		
		task.setTaskCompleted(success: success)
		activeTasks.removeValue(forKey: taskIdentifier)
	}
}

extension String {
	var md5: String {
		Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
	}
}

#endif

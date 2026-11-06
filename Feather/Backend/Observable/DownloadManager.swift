//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import BackgroundTasks

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	/// Paused with resume data; no network activity.
	@Published var isPaused = false
	/// The server supports genuine resume (see ZagResumableDownload).
	@Published var canPause = false
	var bytesBeforePause: Int64 = 0
	/// Set on resume until URLSession reports where it continued from.
	var awaitingResumeCheck = false
	
	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
	var task: URLSessionDownloadTask?
	var resumeData: Data?
	var canRetry: Bool = false
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var zagImported: ((String?, Error?) -> Void)?
	
	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.fileName = url.lastPathComponent
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
	@Published var downloads: [Download] = []
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}
	
	private var _session: URLSession!
	
	#if !targetEnvironment(macCatalyst)
	private func _updateBackgroundAudioState() {
		if #unavailable(iOS 26.0){
			// A paused download needs no keep-alive.
			if downloads.contains(where: { !$0.isPaused }) {
				BackgroundAudioManager.shared.start()
			} else  {
				BackgroundAudioManager.shared.stop()
			}
		}
	}
	#endif
	
	override init() {
		super.init()
		let configuration = URLSessionConfiguration.default
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		zagImported: ((String?, Error?) -> Void)? = nil
	) -> Download {
		if let existingDownload = downloads.first(where: { $0.id == id && $0.url == url }) {
			if let zagImported {
				existingDownload.zagImported = zagImported
			}
			if existingDownload.canRetry { resumeDownload(existingDownload) }
			return existingDownload
		}
		
		let download = Download(id: id, url: url)
		download.zagImported = zagImported
		
		let task = _session.downloadTask(with: url)
		download.task = task
		task.resume()
		
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: download)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		
		return download
	}
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif
		
		return download
	}
	
	func resumeDownload(_ download: Download) {
		download.canRetry = false
		download.isPaused = false
		download.awaitingResumeCheck = false
		// With resume data the transfer continues, so its progress stays.
		if download.resumeData == nil {
			download.progress = 0
			download.bytesDownloaded = 0
			download.totalBytes = 0
		}
		download.unpackageProgress = 0
		if let resumeData = download.resumeData {
			download.resumeData = nil
			let task = _session.downloadTask(withResumeData: resumeData)
			download.task = task
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		} else {
			let task = _session.downloadTask(with: download.url)
			download.task = task
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		}
	}
	
	// MARK: Pause and resume

	/// Stops network activity and keeps resume data. Only offered when the
	/// server supports genuine resume. `completion(false)` means the transfer
	/// stopped without resume data; the job is reported as failed so the user
	/// can retry explicitly, never restarted silently.
	func pauseDownload(_ download: Download, completion: @escaping (Bool) -> Void) {
		guard download.canPause, !download.isPaused, let task = download.task, task.state == .running else {
			completion(false)
			return
		}
		download.isPaused = true
		download.bytesBeforePause = download.bytesDownloaded
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.stopTask(for: download, success: false)
		}
		#endif
		task.cancel(byProducingResumeData: { data in
			DispatchQueue.main.async {
				guard download.task === task else { return }
				if let data, !data.isEmpty {
					download.resumeData = data
					ZagLogger.shared.info("Downloads", "Paused \(download.fileName) at \(download.bytesDownloaded) bytes")
					#if !targetEnvironment(macCatalyst)
					self._updateBackgroundAudioState()
					#endif
					completion(true)
				} else {
					ZagLogger.shared.warning("Downloads", "Pause produced no resume data for \(download.fileName)")
					download.isPaused = false
					download.canRetry = true
					download.zagImported?(nil, ZagDownloadPauseError.notResumable)
					download.zagImported = nil
					#if !targetEnvironment(macCatalyst)
					self._updateBackgroundAudioState()
					#endif
					completion(false)
				}
			}
		})
	}

	/// Continues a paused download from its resume data. Returns false if
	/// there is nothing to resume.
	@discardableResult
	func resumePausedDownload(_ download: Download) -> Bool {
		guard download.isPaused, let data = download.resumeData else { return false }
		download.resumeData = nil
		download.isPaused = false
		download.awaitingResumeCheck = true
		let task = _session.downloadTask(withResumeData: data)
		download.task = task
		task.resume()
		ZagLogger.shared.info("Downloads", "Resuming \(download.fileName) from \(download.bytesBeforePause) bytes")
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: download)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		return true
	}

	/// Removes the partial file a paused download kept, if it is one of
	/// CFNetwork's own temporary files.
	private func _removePartialFile(for resumeData: Data?) {
		guard let resumeData, let name = ZagResumableDownload.partialFileName(inResumeData: resumeData) else { return }
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
		try? FileManager.default.removeItem(at: url)
	}

	func cancelDownload(_ download: Download) {
		_removePartialFile(for: download.resumeData)
		download.isPaused = false
		download.awaitingResumeCheck = false
		download.resumeData = nil
		download.task?.cancel()
		download.zagImported?(nil, URLError(.cancelled))
		download.zagImported = nil
		
		if let index = downloads.firstIndex(where: { $0 === download }) {
			downloads.remove(at: index)
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()

			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download, success: false)
			}
			#endif
		}
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
	func handlePachageFile(url: URL, dl: Download) throws {
		var importedUUID: String?
		FR.handlePackageFile(url, download: dl, importedUUID: { importedUUID = $0 }) { err in
			dl.zagImported?(importedUUID, err)
			dl.zagImported = nil
			if err != nil {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
			}
			
			DispatchQueue.main.async {
				if let index = DownloadManager.shared.downloads.firstIndex(where: { $0 === dl }) {
					DownloadManager.shared.downloads.remove(at: index)
					
					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.updateProgress(for: dl, progress: 1.0)
						BackgroundTaskManager.shared.stopTask(for: dl, success: err == nil)
					}
					
					self._updateBackgroundAudioState()
					#endif
				}
			}
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		let tempDirectory = FileManager.default.temporaryDirectory
		let customTempDir = tempDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = customTempDir.appendingPathComponent(suggestedFileName)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			DispatchQueue.main.async {
				guard let index = self.downloads.firstIndex(where: { $0 === download && $0.task === downloadTask }) else { return }
				download.zagImported?(nil, error)
				download.zagImported = nil
				self.downloads.remove(at: index)

				#if !targetEnvironment(macCatalyst)
				if #available(iOS 26.0, *) {
					BackgroundTaskManager.shared.stopTask(for: download, success: false)
				}
				#endif
			}
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		DispatchQueue.main.async {
			guard download.task === downloadTask, download.awaitingResumeCheck else { return }
			download.awaitingResumeCheck = false
			guard ZagResumableDownload.check(resumedAtOffset: fileOffset, bytesBeforePause: download.bytesBeforePause) == .restartedByServer else {
				ZagLogger.shared.info("Downloads", "Resumed \(download.fileName) at offset \(fileOffset)")
				return
			}
			// Not a resume: stop rather than restart silently. The user can
			// retry explicitly.
			ZagLogger.shared.warning("Downloads", "Server restarted \(download.fileName) from the beginning; stopping")
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download, success: false)
			}
			#endif
			download.task = nil
			downloadTask.cancel()
			download.canRetry = true
			download.zagImported?(nil, ZagDownloadPauseError.serverRestarted)
			download.zagImported = nil
			#if !targetEnvironment(macCatalyst)
			self._updateBackgroundAudioState()
			#endif
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		let response = downloadTask.response as? HTTPURLResponse
		let resumable = response.map { response in
			ZagResumableDownload.supportsResume(
				statusCode: response.statusCode,
				header: { response.value(forHTTPHeaderField: $0) },
				expectedLength: totalBytesExpectedToWrite
			)
		} ?? false

		DispatchQueue.main.async {
			guard self.downloads.contains(where: { $0 === download && $0.task === downloadTask }) else { return }
			guard !download.isPaused else { return }
			if download.canPause != resumable { download.canPause = resumable }
			download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download, progress: download.overallProgress)
			}
			#endif
		}
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let _ = error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}
		
		DispatchQueue.main.async {
			guard self.downloads.contains(where: { $0 === download && $0.task === downloadTask }) else { return }
			// Pausing cancels the transfer on purpose; the pause handler
			// owns the outcome.
			guard !download.isPaused else { return }
			let nsError = error! as NSError
			if nsError.domain == NSURLErrorDomain,
			   let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
			   !data.isEmpty {
				download.resumeData = data
			}
			// A failed transfer ends its background task. A retry continues
			// in the foreground.
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download, success: false)
			}
			#endif
			let hasRepositoryCallback = download.zagImported != nil
			download.canRetry = true
			download.zagImported?(nil, error)
			download.zagImported = nil
			// Retain failed repository downloads for retry; discard failed manual
			// downloads that have no repository button to resume them.
			if !hasRepositoryCallback,
			   let index = self.downloads.firstIndex(where: { $0 === download }) {
				self.downloads.remove(at: index)
			}
		}
	}
}

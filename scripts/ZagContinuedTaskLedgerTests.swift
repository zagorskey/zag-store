import Foundation

// Compiled with Feather/Utilities/ZagOnceCompletion.swift and
// Feather/Utilities/ZagContinuedTaskLedger.swift by
// scripts/test-zag-background-refresh.sh.

/// Stands in for BGContinuedProcessingTask and counts setTaskCompleted calls.
final class FakeTask: @unchecked Sendable {
	private let lock = NSLock()
	private var _calls: [Bool] = []
	var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return _calls }
	func setTaskCompleted(success: Bool) { lock.lock(); _calls.append(success); lock.unlock() }
}

/// Stands in for one URLSessionDownloadTask (one transfer attempt).
final class FakeTransfer: @unchecked Sendable {}

/// Stands in for Download: an identifier plus the transfer it is using now.
final class FakeDownload {
	let id: String
	var task: FakeTransfer?
	init(id: String, task: FakeTransfer) { self.id = id; self.task = task }
}

@main struct ZagContinuedTaskLedgerTests {
	static func main() {
		var failures = 0
		func expect(_ condition: Bool, _ label: String) {
			print((condition ? "PASS  " : "FAIL  ") + label)
			if !condition { failures += 1 }
		}
		let id = "app.zagstore.ios.userTask.0123"

		func launch(_ ledger: ZagContinuedTaskLedger, _ task: FakeTask) -> ZagContinuedTaskLedger.Token? {
			ledger.didLaunch(id, task: task, complete: { task.setTaskCompleted(success: $0) })
		}
		/// What the expiration handler's main-queue block cancels.
		func cancelTarget(_ expired: AnyObject?, _ downloads: [FakeDownload]) -> FakeDownload? {
			ZagContinuedTaskLedger.download(using: expired, in: downloads, transfer: { $0.task })
		}

		// Successful download.
		var ledger = ZagContinuedTaskLedger()
		var task = FakeTask()
		var transfer = FakeTransfer()
		ledger.willSubmit(id, transfer: transfer)
		var token = launch(ledger, task)
		expect(token != nil, "launched task stays running while downloading")
		expect(ledger.runningTask(id, transfer: transfer) === task, "progress updates reach the running task")
		expect(ledger.finish(id, transfer: transfer, success: true) == .completedRunningTask, "finish completes the running task")
		expect(task.calls == [true], "success reported once")
		expect(ledger.finish(id, transfer: transfer, success: false) == .nothing, "second finish is ignored")
		expect(ledger.runningTask(id, transfer: transfer) == nil, "no stale running task")

		// Failed download.
		ledger = ZagContinuedTaskLedger(); task = FakeTask(); transfer = FakeTransfer()
		ledger.willSubmit(id, transfer: transfer); _ = launch(ledger, task)
		ledger.finish(id, transfer: transfer, success: false)
		expect(task.calls == [false], "failed download reports failure once")

		// Expiry: task completed once; cancelDownload's later finish is ignored.
		ledger = ZagContinuedTaskLedger(); task = FakeTask(); transfer = FakeTransfer()
		ledger.willSubmit(id, transfer: transfer); token = launch(ledger, task)
		expect(ledger.expire(id, token: token!) === transfer, "expiry completes the task and names its own transfer to cancel")
		expect(ledger.finish(id, transfer: transfer, success: false) == .nothing, "cancellation after expiry does not complete again")
		expect(task.calls == [false], "expired task completed once")
		expect(ledger.expire(id, token: token!) == nil, "repeated expiry is ignored")

		// Finish then expiry.
		ledger = ZagContinuedTaskLedger(); task = FakeTask(); transfer = FakeTransfer()
		ledger.willSubmit(id, transfer: transfer); token = launch(ledger, task)
		ledger.finish(id, transfer: transfer, success: true)
		expect(ledger.expire(id, token: token!) == nil, "expiry after finish does nothing")
		expect(task.calls == [true], "finished task keeps its result")

		// Download ends before iOS starts the queued task.
		ledger = ZagContinuedTaskLedger(); task = FakeTask(); transfer = FakeTransfer()
		ledger.willSubmit(id, transfer: transfer)
		expect(ledger.finish(id, transfer: transfer, success: true) == .cancelQueuedRequest, "queued request is cancelled when the download ends first")
		expect(launch(ledger, task) == nil, "late launch is not kept running")
		expect(task.calls == [true], "late launch completed immediately with the download's result")
		task = FakeTask()
		expect(launch(ledger, task) == nil && task.calls == [false], "unknown launch is completed immediately")

		// Rejected submission leaves no state behind.
		ledger = ZagContinuedTaskLedger(); transfer = FakeTransfer()
		ledger.willSubmit(id, transfer: transfer); ledger.submitFailed(id, transfer: transfer)
		expect(ledger.finish(id, transfer: transfer, success: true) == .nothing, "rejected submission is forgotten")

		// Restarting a download with the same identifier.
		ledger = ZagContinuedTaskLedger()
		var old = FakeTask(), new = FakeTask()
		var oldTransfer = FakeTransfer(), newTransfer = FakeTransfer()
		ledger.willSubmit(id, transfer: oldTransfer); let oldToken = launch(ledger, old)!
		ledger.willSubmit(id, transfer: newTransfer)
		expect(old.calls == [false], "replaced task is completed")
		let newToken = launch(ledger, new)!
		expect(ledger.expire(id, token: oldToken) == nil, "stale expiry does not cancel the new download")
		expect(ledger.runningTask(id, transfer: newTransfer) === new, "new task still running after stale expiry")
		expect(ledger.runningTask(id, transfer: oldTransfer) == nil, "old transfer no longer receives progress")
		ledger.finish(id, transfer: newTransfer, success: true)
		expect(old.calls == [false] && new.calls == [true], "each task completed exactly once")
		expect(ledger.expire(id, token: newToken) == nil, "expiry after finish ignored")

		// Regression: expiry races a replacement download.
		// iOS expires the old task on its queue; the cancel runs later on the
		// main queue. Before it runs, the old download is removed and a new
		// download starts with the same identifier. The old code looked the
		// download up by identifier and cancelled the replacement.
		ledger = ZagContinuedTaskLedger()
		old = FakeTask(); new = FakeTask(); oldTransfer = FakeTransfer(); newTransfer = FakeTransfer()
		let oldDownload = FakeDownload(id: id, task: oldTransfer)
		var downloads = [oldDownload]
		ledger.willSubmit(id, transfer: oldTransfer)
		let racedToken = launch(ledger, old)!
		let expired = ledger.expire(id, token: racedToken)          // background queue
		expect(expired === oldTransfer, "expiry asks to cancel only the old transfer")
		downloads.removeAll { $0 === oldDownload }                    // main: old download ends
		ledger.finish(id, transfer: oldTransfer, success: false)
		let replacement = FakeDownload(id: id, task: newTransfer)     // main: replacement starts
		downloads.append(replacement)
		ledger.willSubmit(id, transfer: newTransfer)
		_ = launch(ledger, new)
		expect(downloads.first { $0.id == id } === replacement,
		       "scenario reproduces the race: an identifier lookup finds the replacement")
		expect(cancelTarget(expired, downloads) == nil, "delayed cancel does not touch the replacement download")
		expect(new.calls.isEmpty && ledger.runningTask(id, transfer: newTransfer) === new,
		       "replacement keeps its running background task")
		expect(old.calls == [false], "expired task completed once")

		// Regression: expiry races a retry of the same download object.
		ledger = ZagContinuedTaskLedger(); task = FakeTask(); transfer = FakeTransfer()
		let retried = FakeDownload(id: id, task: transfer)
		ledger.willSubmit(id, transfer: transfer)
		let retryToken = launch(ledger, task)!
		let expiredBeforeRetry = ledger.expire(id, token: retryToken)
		ledger.finish(id, transfer: transfer, success: false)         // main: transfer failed
		retried.task = FakeTransfer()                                 // main: user retries
		expect(cancelTarget(expiredBeforeRetry, [retried]) == nil, "delayed cancel does not stop a retried transfer")

		// The expired download is still cancelled when nothing replaced it.
		ledger = ZagContinuedTaskLedger(); task = FakeTask(); transfer = FakeTransfer()
		let still = FakeDownload(id: id, task: transfer)
		ledger.willSubmit(id, transfer: transfer)
		let stillToken = launch(ledger, task)!
		expect(cancelTarget(ledger.expire(id, token: stillToken), [still]) === still, "expired download is cancelled")

		// Two downloads share an identifier (same id, different URL): ending
		// the old one must not end the new one's background task.
		ledger = ZagContinuedTaskLedger()
		new = FakeTask(); oldTransfer = FakeTransfer(); newTransfer = FakeTransfer()
		ledger.willSubmit(id, transfer: oldTransfer)
		ledger.willSubmit(id, transfer: newTransfer)
		expect(ledger.finish(id, transfer: oldTransfer, success: false) == .nothing,
		       "old download does not cancel the replacement's queued request")
		_ = launch(ledger, new)
		expect(ledger.finish(id, transfer: oldTransfer, success: false) == .nothing && new.calls.isEmpty,
		       "old download does not end the replacement's running task")
		expect(ledger.finish(id, transfer: newTransfer, success: true) == .completedRunningTask && new.calls == [true],
		       "replacement ends its own task with its result")

		// Registration happens once per identifier.
		ledger = ZagContinuedTaskLedger()
		expect(!ledger.isRegistered(id), "new identifier needs registration")
		ledger.markRegistered(id)
		expect(ledger.isRegistered(id), "registered identifier is not registered again")

		// Completion/expiration races from different threads.
		var bad = 0
		for round in 0..<2_000 {
			let racing = ZagContinuedTaskLedger(), raced = FakeTask(), racedTransfer = FakeTransfer()
			racing.willSubmit(id, transfer: racedTransfer)
			let racingToken = racing.didLaunch(id, task: raced, complete: { raced.setTaskCompleted(success: $0) })!
			let group = DispatchGroup()
			let lock = NSLock()
			var cancelled: AnyObject?
			DispatchQueue.global().async(group: group) { racing.finish(id, transfer: racedTransfer, success: true) }
			DispatchQueue.global().async(group: group) {
				let target = racing.expire(id, token: racingToken)
				lock.lock(); cancelled = target; lock.unlock()
			}
			if round.isMultiple(of: 2) {
				DispatchQueue.global().async(group: group) { racing.finish(id, transfer: racedTransfer, success: false) }
			}
			group.wait()
			// Exactly one completion. With only a successful finish racing,
			// expiry asks for a cancel exactly when it ended the task.
			if raced.calls.count != 1 { bad += 1 }
			let onlySuccessRaced = !round.isMultiple(of: 2)
			if onlySuccessRaced && (cancelled != nil) != (raced.calls == [false]) { bad += 1 }
		}
		expect(bad == 0, "2000 finish/expiry races complete exactly once")

		// Expiry of the old task racing a replacement submission.
		bad = 0
		for _ in 0..<2_000 {
			let racing = ZagContinuedTaskLedger(), first = FakeTask(), second = FakeTask()
			let a = FakeTransfer(), b = FakeTransfer()
			racing.willSubmit(id, transfer: a)
			let firstToken = racing.didLaunch(id, task: first, complete: { first.setTaskCompleted(success: $0) })!
			let group = DispatchGroup()
			let lock = NSLock()
			var cancelled: AnyObject?
			DispatchQueue.global().async(group: group) {
				let target = racing.expire(id, token: firstToken)
				lock.lock(); cancelled = target; lock.unlock()
			}
			DispatchQueue.global().async(group: group) { racing.willSubmit(id, transfer: b) }
			group.wait()
			_ = racing.didLaunch(id, task: second, complete: { second.setTaskCompleted(success: $0) })
			if first.calls != [false] { bad += 1 }
			if cancelled != nil && cancelled !== a { bad += 1 }
			if !second.calls.isEmpty || racing.runningTask(id, transfer: b) !== second { bad += 1 }
		}
		expect(bad == 0, "2000 expiry/replacement races never touch the replacement")

		// Launch racing with finish while queued.
		bad = 0
		for _ in 0..<2_000 {
			let racing = ZagContinuedTaskLedger(), raced = FakeTask(), racedTransfer = FakeTransfer()
			racing.willSubmit(id, transfer: racedTransfer)
			let group = DispatchGroup()
			DispatchQueue.global().async(group: group) { racing.finish(id, transfer: racedTransfer, success: true) }
			DispatchQueue.global().async(group: group) {
				_ = racing.didLaunch(id, task: raced, complete: { raced.setTaskCompleted(success: $0) })
			}
			group.wait()
			if raced.calls != [true] { bad += 1 }
		}
		expect(bad == 0, "2000 launch/finish races complete once with the download's result")

		if failures > 0 {
			print("\(failures) test(s) failed")
			exit(1)
		}
		print("All continued-task ledger tests passed")
	}
}

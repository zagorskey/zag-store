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

		// Successful download.
		var ledger = ZagContinuedTaskLedger()
		var task = FakeTask()
		ledger.willSubmit(id)
		var token = launch(ledger, task)
		expect(token != nil, "launched task stays running while downloading")
		expect(ledger.runningTask(id) === task, "progress updates reach the running task")
		expect(ledger.finish(id, success: true) == .completedRunningTask, "finish completes the running task")
		expect(task.calls == [true], "success reported once")
		expect(ledger.finish(id, success: false) == .nothing, "second finish is ignored")
		expect(ledger.runningTask(id) == nil, "no stale running task")

		// Failed download.
		ledger = ZagContinuedTaskLedger(); task = FakeTask()
		ledger.willSubmit(id); _ = launch(ledger, task)
		ledger.finish(id, success: false)
		expect(task.calls == [false], "failed download reports failure once")

		// Expiry: task completed once; cancelDownload's later finish is ignored.
		ledger = ZagContinuedTaskLedger(); task = FakeTask()
		ledger.willSubmit(id); token = launch(ledger, task)
		expect(ledger.expire(id, token: token!), "expiry completes the task and asks to cancel the download")
		expect(ledger.finish(id, success: false) == .nothing, "cancellation after expiry does not complete again")
		expect(task.calls == [false], "expired task completed once")
		expect(!ledger.expire(id, token: token!), "repeated expiry is ignored")

		// Finish then expiry.
		ledger = ZagContinuedTaskLedger(); task = FakeTask()
		ledger.willSubmit(id); token = launch(ledger, task)
		ledger.finish(id, success: true)
		expect(!ledger.expire(id, token: token!), "expiry after finish does nothing")
		expect(task.calls == [true], "finished task keeps its result")

		// Download ends before iOS starts the queued task.
		ledger = ZagContinuedTaskLedger(); task = FakeTask()
		ledger.willSubmit(id)
		expect(ledger.finish(id, success: true) == .cancelQueuedRequest, "queued request is cancelled when the download ends first")
		expect(launch(ledger, task) == nil, "late launch is not kept running")
		expect(task.calls == [true], "late launch completed immediately with the download's result")
		task = FakeTask()
		expect(launch(ledger, task) == nil && task.calls == [false], "unknown launch is completed immediately")

		// Rejected submission leaves no state behind.
		ledger = ZagContinuedTaskLedger(); task = FakeTask()
		ledger.willSubmit(id); ledger.submitFailed(id)
		expect(ledger.finish(id, success: true) == .nothing, "rejected submission is forgotten")

		// Restarting a download with the same identifier.
		ledger = ZagContinuedTaskLedger()
		let old = FakeTask(), new = FakeTask()
		ledger.willSubmit(id); let oldToken = launch(ledger, old)!
		ledger.willSubmit(id)
		expect(old.calls == [false], "replaced task is completed")
		let newToken = launch(ledger, new)!
		expect(!ledger.expire(id, token: oldToken), "stale expiry does not cancel the new download")
		expect(ledger.runningTask(id) === new, "new task still running after stale expiry")
		ledger.finish(id, success: true)
		expect(old.calls == [false] && new.calls == [true], "each task completed exactly once")
		expect(!ledger.expire(id, token: newToken), "expiry after finish ignored")

		// Registration happens once per identifier.
		ledger = ZagContinuedTaskLedger()
		expect(!ledger.isRegistered(id), "new identifier needs registration")
		ledger.markRegistered(id)
		expect(ledger.isRegistered(id), "registered identifier is not registered again")

		// Completion/expiration races from different threads.
		var bad = 0
		for round in 0..<2_000 {
			let racing = ZagContinuedTaskLedger(), raced = FakeTask()
			racing.willSubmit(id)
			let racingToken = racing.didLaunch(id, task: raced, complete: { raced.setTaskCompleted(success: $0) })!
			let group = DispatchGroup()
			DispatchQueue.global().async(group: group) { racing.finish(id, success: true) }
			DispatchQueue.global().async(group: group) { _ = racing.expire(id, token: racingToken) }
			if round.isMultiple(of: 2) {
				DispatchQueue.global().async(group: group) { racing.finish(id, success: false) }
			}
			group.wait()
			if raced.calls.count != 1 { bad += 1 }
		}
		expect(bad == 0, "2000 finish/expiry races complete exactly once")

		// Launch racing with finish while queued.
		bad = 0
		for _ in 0..<2_000 {
			let racing = ZagContinuedTaskLedger(), raced = FakeTask()
			racing.willSubmit(id)
			let group = DispatchGroup()
			DispatchQueue.global().async(group: group) { racing.finish(id, success: true) }
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

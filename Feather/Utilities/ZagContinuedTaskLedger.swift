import Foundation

/// Tracks continued-processing download tasks so each one is completed
/// exactly once, whichever happens first: the download finishing, failing or
/// being cancelled, iOS expiring the task, or iOS starting the task only
/// after the download has already ended.
///
/// Thread-safe. iOS calls launch and expiration handlers on a background
/// queue, while downloads report on the main queue.
final class ZagContinuedTaskLedger: @unchecked Sendable {
	/// Identifies one running task, so a stale expiration cannot affect a
	/// newer task that reuses the same identifier.
	final class Token: @unchecked Sendable {
		fileprivate let completion: ZagOnceCompletion
		fileprivate let task: AnyObject
		fileprivate init(task: AnyObject, complete: @escaping (Bool) -> Void) {
			self.task = task
			self.completion = ZagOnceCompletion(complete)
		}
	}

	enum FinishOutcome: Equatable {
		/// A running task was completed with the download's result.
		case completedRunningTask
		/// The request had not started yet; cancel it with the scheduler.
		/// If iOS starts it anyway, it is completed immediately.
		case cancelQueuedRequest
		/// Nothing to do: no task, or it was already completed.
		case nothing
	}

	private enum State {
		case queued
		case running(Token)
		case finished(Bool)
	}

	private let lock = NSLock()
	private var registered: Set<String> = []
	private var states: [String: State] = [:]

	// MARK: Registration (iOS kills the app on a second registration)

	func isRegistered(_ id: String) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return registered.contains(id)
	}

	func markRegistered(_ id: String) {
		lock.lock(); defer { lock.unlock() }
		registered.insert(id)
	}

	// MARK: Lifecycle

	/// A request is about to be submitted. A task still running for this
	/// identifier belongs to a download being replaced, so it is completed.
	func willSubmit(_ id: String) {
		lock.lock()
		var replaced: Token?
		if case .running(let token) = states[id] { replaced = token }
		states[id] = .queued
		lock.unlock()
		replaced?.completion.complete(success: false)
	}

	/// The scheduler rejected the request, so no task will start.
	func submitFailed(_ id: String) {
		lock.lock(); defer { lock.unlock() }
		if case .queued = states[id] { states[id] = nil }
	}

	/// iOS started the task. Returns a token while the download is still
	/// running. Otherwise the task is completed immediately (with the
	/// download's result if known) and nil is returned.
	func didLaunch(_ id: String, task: AnyObject, complete: @escaping (Bool) -> Void) -> Token? {
		lock.lock()
		switch states[id] {
		case .queued:
			let token = Token(task: task, complete: complete)
			states[id] = .running(token)
			lock.unlock()
			return token
		case .running(let previous):
			// Unexpected second launch: keep the newest task, end the old one.
			let token = Token(task: task, complete: complete)
			states[id] = .running(token)
			lock.unlock()
			previous.completion.complete(success: false)
			return token
		case .finished(let success):
			states[id] = nil
			lock.unlock()
			complete(success)
			return nil
		case nil:
			lock.unlock()
			complete(false)
			return nil
		}
	}

	/// The download ended (finished, failed or cancelled).
	@discardableResult
	func finish(_ id: String, success: Bool) -> FinishOutcome {
		lock.lock()
		switch states[id] {
		case .running(let token):
			states[id] = nil
			lock.unlock()
			return token.completion.complete(success: success) ? .completedRunningTask : .nothing
		case .queued:
			states[id] = .finished(success)
			lock.unlock()
			return .cancelQueuedRequest
		case .finished, nil:
			lock.unlock()
			return .nothing
		}
	}

	/// iOS is expiring the task. Returns true if this call completed it,
	/// meaning the caller should cancel the download.
	func expire(_ id: String, token: Token) -> Bool {
		lock.lock()
		if case .running(let current) = states[id], current === token {
			states[id] = nil
		}
		lock.unlock()
		return token.completion.complete(success: false)
	}

	/// The running task for an identifier, for progress updates.
	func runningTask(_ id: String) -> AnyObject? {
		lock.lock(); defer { lock.unlock() }
		if case .running(let token) = states[id] { return token.task }
		return nil
	}
}

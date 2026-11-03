import Foundation

/// Tracks continued-processing download tasks so each one is completed
/// exactly once, whichever happens first: the download finishing, failing or
/// being cancelled, iOS expiring the task, or iOS starting the task only
/// after the download has already ended.
///
/// Every submission belongs to one transfer (the URLSessionTask that was
/// running when it was submitted). Finishing, expiring and progress only act
/// on the entry for that exact transfer, so an old task can never end or
/// cancel a replacement download that reuses the identifier.
///
/// Thread-safe. iOS calls launch and expiration handlers on a background
/// queue, while downloads report on the main queue.
final class ZagContinuedTaskLedger: @unchecked Sendable {
	/// Identifies one running task, so a stale expiration cannot affect a
	/// newer task that reuses the same identifier.
	final class Token: @unchecked Sendable {
		fileprivate let completion: ZagOnceCompletion
		fileprivate let task: AnyObject
		fileprivate weak var transfer: AnyObject?
		fileprivate init(task: AnyObject, transfer: AnyObject?, complete: @escaping (Bool) -> Void) {
			self.task = task
			self.transfer = transfer
			self.completion = ZagOnceCompletion(complete)
		}
	}

	enum FinishOutcome: Equatable {
		/// A running task was completed with the download's result.
		case completedRunningTask
		/// The request had not started yet; cancel it with the scheduler.
		/// If iOS starts it anyway, it is completed immediately.
		case cancelQueuedRequest
		/// Nothing to do: no task, already completed, or the entry belongs
		/// to a different transfer.
		case nothing
	}

	private final class WeakTransfer {
		weak var value: AnyObject?
		init(_ value: AnyObject) { self.value = value }
	}

	private enum State {
		case queued(WeakTransfer)
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

	/// A request is about to be submitted for `transfer`. A task still
	/// running for this identifier belongs to a download being replaced, so
	/// it is completed.
	func willSubmit(_ id: String, transfer: AnyObject) {
		lock.lock()
		var replaced: Token?
		if case .running(let token) = states[id] { replaced = token }
		states[id] = .queued(WeakTransfer(transfer))
		lock.unlock()
		replaced?.completion.complete(success: false)
	}

	/// The scheduler rejected the request, so no task will start.
	func submitFailed(_ id: String, transfer: AnyObject) {
		lock.lock(); defer { lock.unlock() }
		if case .queued(let owner) = states[id], owner.value === transfer { states[id] = nil }
	}

	/// iOS started the task. Returns a token while the download is still
	/// running. Otherwise the task is completed immediately (with the
	/// download's result if known) and nil is returned.
	func didLaunch(_ id: String, task: AnyObject, complete: @escaping (Bool) -> Void) -> Token? {
		lock.lock()
		switch states[id] {
		case .queued(let owner):
			let token = Token(task: task, transfer: owner.value, complete: complete)
			states[id] = .running(token)
			lock.unlock()
			return token
		case .running(let previous):
			// Unexpected second launch: keep the newest task, end the old one.
			let token = Token(task: task, transfer: previous.transfer, complete: complete)
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

	/// The download using `transfer` ended (finished, failed or cancelled).
	/// Does nothing if the identifier now belongs to another transfer.
	@discardableResult
	func finish(_ id: String, transfer: AnyObject, success: Bool) -> FinishOutcome {
		lock.lock()
		switch states[id] {
		case .running(let token) where token.transfer === transfer:
			states[id] = nil
			lock.unlock()
			return token.completion.complete(success: success) ? .completedRunningTask : .nothing
		case .queued(let owner) where owner.value === transfer:
			states[id] = .finished(success)
			lock.unlock()
			return .cancelQueuedRequest
		default:
			lock.unlock()
			return .nothing
		}
	}

	/// iOS is expiring the task. Returns the transfer to cancel, or nil.
	///
	/// Only the current task may cancel anything, and only the transfer it
	/// was submitted for. A token that is no longer current is already
	/// being completed by whoever replaced or finished it, so it is left
	/// alone: completing it here could overwrite a successful result.
	func expire(_ id: String, token: Token) -> AnyObject? {
		lock.lock()
		guard case .running(let current) = states[id], current === token else {
			lock.unlock()
			return nil
		}
		states[id] = nil
		lock.unlock()
		guard token.completion.complete(success: false) else { return nil }
		return token.transfer
	}

	/// The running task for an identifier, if it belongs to `transfer`.
	func runningTask(_ id: String, transfer: AnyObject) -> AnyObject? {
		lock.lock(); defer { lock.unlock() }
		if case .running(let token) = states[id], token.transfer === transfer { return token.task }
		return nil
	}

	/// The download to cancel after an expiry: the one still using the
	/// expired transfer. A replacement or retried download has a different
	/// transfer and is never returned, even if it shares the identifier.
	/// Call on the queue that owns `downloads`.
	static func download<D: AnyObject>(
		using expiredTransfer: AnyObject?,
		in downloads: [D],
		transfer: (D) -> AnyObject?
	) -> D? {
		guard let expiredTransfer else { return nil }
		return downloads.first { transfer($0) === expiredTransfer }
	}
}

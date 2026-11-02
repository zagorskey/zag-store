import Foundation

/// Runs a completion handler at most once, from any thread.
///
/// Background tasks must report completion exactly once, whether the work
/// finishes or iOS expires the task first.
final class ZagOnceCompletion: @unchecked Sendable {
	private let lock = NSLock()
	private var handler: ((Bool) -> Void)?

	init(_ handler: @escaping (Bool) -> Void) {
		self.handler = handler
	}

	/// Returns true if this call ran the handler.
	@discardableResult
	func complete(success: Bool) -> Bool {
		lock.lock()
		let pending = handler
		handler = nil
		lock.unlock()
		guard let pending else { return false }
		pending(success)
		return true
	}
}

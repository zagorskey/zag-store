import Combine
import Foundation

/// Logs main-thread stalls of 200 ms or more while an install job is
/// running, with the job stages at the time, so slow work on the main
/// thread can be found from a device log. Logs timing and stage only.
@MainActor
final class ZagMainThreadStallMonitor {
	static let shared = ZagMainThreadStallMonitor()

	private static let threshold: TimeInterval = 0.2
	private let queue = DispatchQueue(label: "zag.main-thread-stall-monitor", qos: .utility)
	private var timer: DispatchSourceTimer?
	private var watch: AnyCancellable?
	/// Touched only on `queue`.
	nonisolated(unsafe) private var pingPending = false

	private init() {}

	/// Idempotent; runs the probe only while jobs exist.
	func start() {
		guard watch == nil else { return }
		watch = ZagInstallJobs.shared.$jobs
			.map { !$0.isEmpty }
			.removeDuplicates()
			.sink { [weak self] active in
				if active { self?._resume() } else { self?._pause() }
			}
	}

	private func _resume() {
		guard timer == nil else { return }
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
		timer.setEventHandler { [weak self] in self?._ping() }
		timer.resume()
		self.timer = timer
	}

	private func _pause() {
		timer?.cancel()
		timer = nil
	}

	nonisolated private func _ping() {
		guard !pingPending else { return }
		pingPending = true
		let sent = DispatchTime.now()
		DispatchQueue.main.async { [weak self] in
			let delay = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e9
			self?.queue.async { self?.pingPending = false }
			guard delay >= Self.threshold else { return }
			MainActor.assumeIsolated {
				let stages = ZagInstallJobs.shared.jobs.values.map { "\($0.stage)" }.sorted().joined(separator: ",")
				ZagLogger.shared.warning("Performance", "Main thread stalled \(Int(delay * 1000)) ms | stages=\(stages.isEmpty ? "none" : stages)")
			}
		}
	}
}

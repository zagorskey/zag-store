import Combine
import UIKit

/// Temporary diagnostic: launches the user's "Zag Cellular Off" Shortcut from
/// Zag Store with the public UIApplication.open API, and records:
/// - whether iOS accepted the hand-off;
/// - whether Zag Store left and re-entered the foreground;
/// - whether the matching x-callback arrived (success, cancel or error);
/// - whether RemotePairing then became reachable, confirmed by the real
///   full health check rather than by the callback alone.
/// It never changes system settings itself and touches no install code.
@MainActor
final class ZagShortcutLaunchTest: ObservableObject {
	static let shared = ZagShortcutLaunchTest()
	static let shortcutName = "Zag Cellular Off"

	struct Event: Identifiable {
		let id = UUID()
		let milliseconds: Int
		let text: String
	}

	@Published private(set) var events: [Event] = []
	@Published private(set) var running = false

	private var run: String?
	private var startedAt: TimeInterval = 0
	private var callbackReceived = false
	private var observers: [NSObjectProtocol] = []
	private var readinessTask: Task<Void, Never>?
	private var healthWatch: AnyCancellable?

	private init() {}

	func start() {
		guard !running else { return }
		events = []
		let run = UUID().uuidString
		self.run = run
		startedAt = ProcessInfo.processInfo.systemUptime
		callbackReceived = false
		running = true
		log("Before: \(networkSummary())")

		guard let url = ZagShortcutCallback.launchURL(shortcutName: Self.shortcutName, run: run) else {
			log("Could not build the Shortcuts URL")
			finish()
			return
		}
		watchForeground()
		log("UIApplication.open requested for \"\(Self.shortcutName)\"")
		UIApplication.shared.open(url, options: [:]) { [weak self] accepted in
			Task { @MainActor in
				guard let self, self.run == run else { return }
				self.log(accepted ? "Hand-off accepted by iOS" : "Hand-off rejected by iOS (Shortcuts unavailable?)")
				if !accepted { self.finish() }
			}
		}
	}

	func cancel() {
		guard running else { return }
		log("Test cancelled")
		finish()
	}

	/// Consumes Zag Store's shortcut callbacks only; returns false for every
	/// other URL so existing deep links are unaffected.
	func handle(_ url: URL) -> Bool {
		guard let outcome = ZagShortcutCallback.parse(url) else { return false }
		guard running, outcome.run == run, !callbackReceived else {
			log("Ignored a callback that does not belong to the current test")
			return true
		}
		callbackReceived = true
		switch outcome {
		case .success:
			log("Callback received: success")
			verifyReadiness()
		case .cancel:
			log("Callback received: cancelled in Shortcuts")
			finish()
		case .error(_, let message):
			log("Callback received: error\(message.map { " (\($0))" } ?? "")")
			finish()
		}
		return true
	}

	func report() -> String {
		var lines = [
			"Zag Store Shortcut launch test",
			"Shortcut: \(Self.shortcutName)",
			"Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)",
		]
		lines += events.map { "[+\($0.milliseconds) ms] \($0.text)" }
		return ZagDiagnosticReport.redact(lines.joined(separator: "\n"))
	}

	// MARK: - Steps

	private func watchForeground() {
		removeObservers()
		observers.append(NotificationCenter.default.addObserver(
			forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor in self?.log("Zag Store left the foreground") }
		})
		observers.append(NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				guard let self, self.running else { return }
				self.log("Zag Store active again")
				// Allow the callback a moment to arrive after activation.
				try? await Task.sleep(nanoseconds: 1_500_000_000)
				if self.running, !self.callbackReceived {
					self.log("Returned without a callback")
					self.callbackReceived = true
					self.verifyReadiness()
				}
			}
		})
	}

	/// Up to three connect-only checks of 10.7.0.1:49152 (at 0.5, 2.5 and
	/// 7.5 s), then the real full health check once the endpoint accepts.
	private func verifyReadiness() {
		readinessTask?.cancel()
		readinessTask = Task { @MainActor [weak self] in
			for (index, delay) in [0.5, 2.0, 5.0].enumerated() {
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				guard let self, !Task.isCancelled, self.running else { return }
				let probe = await ZagEndpointProbe.connect(timeout: 2)
				self.log("Check \(index + 1): \(self.networkSummary()); \(ZagDeviceLink.peerAddress):\(ZagDeviceLink.rsdPort) \(ZagTransportTrace.describe(probe))")
				if case .accepted = probe {
					self.runHealthCheck()
					return
				}
			}
			guard let self, self.running else { return }
			self.log("RemotePairing did not become reachable")
			self.finish()
		}
	}

	private func runHealthCheck() {
		let core = ZagRPPairingCore.shared
		guard core.pairingFileExists, !core.isTransportBusy, !core.isGate2Running else {
			log("Full health check skipped (no pairing file or a session is already running)")
			finish()
			return
		}
		log("Starting full health check")
		healthWatch = core.$gate2State.dropFirst().sink { [weak self] state in
			guard let self else { return }
			switch state {
			case .complete:
				self.log("Full health check passed: RPPairing is ready")
				self.finish()
			case .failed(let message):
				self.log("Full health check failed: \(message)")
				self.finish()
			default:
				break
			}
		}
		core.startGate2Probe()
	}

	private func finish() {
		running = false
		readinessTask?.cancel()
		readinessTask = nil
		healthWatch = nil
		removeObservers()
	}

	private func removeObservers() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers = []
	}

	private func networkSummary() -> String {
		let networks = ZagLocalVPNMonitor.shared.physicalNetworks
		let tunnel = ZagLocalVPNMonitor.tunnelInterfaceNames()
		return "network \(networks.isEmpty ? "none" : networks.joined(separator: ", ")); LocalDevVPN interface \(tunnel.isEmpty ? "not present" : "present")"
	}

	private func log(_ text: String) {
		let ms = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
		events.append(Event(milliseconds: ms, text: text))
	}
}

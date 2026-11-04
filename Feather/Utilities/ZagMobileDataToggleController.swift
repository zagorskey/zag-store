import Combine
import UIKit

/// Runs the "Zag Mobile Data Toggle" Shortcut and keeps its setup state.
///
/// - One operation at a time, each with a random id and a bounded lifetime.
/// - Only Zag Store's own callback URLs are consumed; they can never start
///   or resume an installation.
/// - A callback is never taken as proof that Mobile Data changed: after
///   `off`, readiness is confirmed by the RPPairing health check; after `on`,
///   the system network path must show cellular again.
/// - It only runs when the user taps, and never retries on its own.
/// Installation, signing and self-update code are untouched.
@MainActor
final class ZagMobileDataToggleController: ObservableObject {
	typealias Toggle = ZagMobileDataToggle

	static let shared = ZagMobileDataToggleController()
	private static let recordKey = "ZagStore.mobileDataToggle.record.v1"

	struct Event: Identifiable {
		let id = UUID()
		let milliseconds: Int
		let text: String
	}

	enum Activity: Equatable {
		case idle
		case waiting(Toggle.Command)
		case checkingReadiness
	}

	@Published private(set) var record: Toggle.Record
	@Published private(set) var activity: Activity = .idle
	@Published private(set) var lastMessage: String?
	@Published private(set) var events: [Event] = []

	private var pending: Toggle.Operation?
	private var startedAt: TimeInterval = 0
	private var observers: [NSObjectProtocol] = []
	private var timeoutTask: Task<Void, Never>?
	private var followUpTask: Task<Void, Never>?
	private var healthWatch: AnyCancellable?

	private init() {
		let data = UserDefaults.standard.data(forKey: Self.recordKey)
		record = data.flatMap { try? JSONDecoder().decode(Toggle.Record.self, from: $0) } ?? Toggle.Record()
	}

	var status: Toggle.Status { Toggle.status(of: record) }
	var isBusy: Bool { activity != .idle }

	// MARK: - Actions

	func openSetupPage() {
		update { $0.setupPageOpenedAt = Date() }
		UIApplication.shared.open(Toggle.setupPage, options: [:])
	}

	func verify() { run(.status) }

	func run(_ command: Toggle.Command) {
		guard !isBusy else { return }
		let operation = Toggle.Operation.new(command)
		guard let url = Toggle.launchURL(for: operation) else { return }

		events = []
		startedAt = ProcessInfo.processInfo.systemUptime
		pending = operation
		activity = .waiting(command)
		lastMessage = nil
		log("Running \"\(Toggle.shortcutName)\" with \(command.rawValue). \(networkSummary())")
		watchForeground(for: operation)
		scheduleTimeout(for: operation)

		UIApplication.shared.open(url, options: [:]) { [weak self] accepted in
			Task { @MainActor in
				guard let self, self.pending == operation else { return }
				self.log(accepted ? "iOS opened Shortcuts" : "iOS could not open Shortcuts")
				if !accepted { self.complete(operation, .handOffRejected) }
			}
		}
	}

	func cancel() {
		guard isBusy else { return }
		log("Cancelled in Zag Store; later callbacks for this run are ignored")
		pending = nil
		lastMessage = "Cancelled."
		endActivity()
	}

	/// Consumes every zagstore://shortcut-callback/… URL and nothing else.
	func handle(_ url: URL) -> Bool {
		guard Toggle.isCallback(url) else { return false }
		guard let callback = Toggle.parse(url) else {
			log("Ignored a malformed Shortcut callback")
			return true
		}
		let names = callback.parameterNames.joined(separator: ", ")
		switch Toggle.evaluate(callback, pending: pending) {
		case .ignore(let reason):
			log("Ignored a \(callback.outcome.rawValue) callback: \(reason)")
		case .complete(let completion):
			log("Callback: \(callback.outcome.rawValue); parameters [\(names)]; result \(describe(callback.result))\(callback.errorMessage.map { "; errorMessage \(describe($0))" } ?? "")")
			if let operation = pending { complete(operation, completion) }
		}
		return true
	}

	func report() -> String {
		var lines = [
			"Zag Mobile Data Toggle log",
			"Status: \(status.title)",
			"Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)",
		]
		lines += events.map { "[+\($0.milliseconds) ms] \($0.text)" }
		return ZagDiagnosticReport.redact(lines.joined(separator: "\n"))
	}

	// MARK: - Completion

	private func complete(_ operation: Toggle.Operation, _ completion: Toggle.Completion) {
		guard pending == operation else { return }
		pending = nil
		timeoutTask?.cancel()
		removeObservers()
		update { $0 = Toggle.record($0, after: completion) }

		let message = Toggle.message(for: completion)
		log("\(operation.command.rawValue): \(message)")
		lastMessage = message

		guard completion == .confirmed else {
			endActivity()
			return
		}
		switch operation.command {
		case .status:
			lastMessage = "\(Toggle.shortcutName) is verified."
			endActivity()
		case .off:
			checkReadiness()
		case .on:
			checkCellularReturned()
		}
	}

	/// Up to three connect-only checks of the RemotePairing port, then the
	/// full health check as the only readiness verdict.
	private func checkReadiness() {
		activity = .checkingReadiness
		followUpTask = Task { @MainActor [weak self] in
			for (index, delay) in [0.5, 2.0, 5.0].enumerated() {
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				guard let self, !Task.isCancelled, self.activity == .checkingReadiness else { return }
				let probe = await ZagEndpointProbe.connect(timeout: 2)
				self.log("Check \(index + 1): \(self.networkSummary()); RemotePairing \(ZagTransportTrace.describe(probe))")
				if case .accepted = probe {
					self.runHealthCheck()
					return
				}
			}
			guard let self, self.activity == .checkingReadiness else { return }
			self.finishReadiness("RemotePairing did not become reachable. Mobile Data may still be on.")
		}
	}

	private func runHealthCheck() {
		let core = ZagRPPairingCore.shared
		guard core.pairingFileExists, !core.isTransportBusy, !core.isGate2Running else {
			finishReadiness("RemotePairing answers, but the health check could not run now.")
			return
		}
		log("Running the full health check")
		healthWatch = core.$gate2State.dropFirst().sink { [weak self] state in
			switch state {
			case .complete: self?.finishReadiness("RPPairing is ready.")
			case .failed(let message): self?.finishReadiness("Health check failed: \(message)")
			default: break
			}
		}
		core.startGate2Probe()
	}

	private func finishReadiness(_ message: String) {
		log(message)
		lastMessage = message
		endActivity()
	}

	/// Reports restoration only when the system path shows cellular again.
	private func checkCellularReturned() {
		activity = .checkingReadiness
		followUpTask = Task { @MainActor [weak self] in
			for delay in [1.0, 3.0] {
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				guard let self, !Task.isCancelled, self.activity == .checkingReadiness else { return }
				ZagLocalVPNMonitor.shared.startIfNeeded()
				ZagLocalVPNMonitor.shared.refresh()
				let summary = self.networkSummary()
				self.log("Check: \(summary)")
				if ZagLocalVPNMonitor.shared.physicalNetworks.contains("Cellular") {
					self.finishReadiness("Mobile Data appears to be on.")
					return
				}
			}
			guard let self, self.activity == .checkingReadiness else { return }
			self.finishReadiness("The Shortcut replied, but Zag Store cannot confirm Mobile Data is back on. Check Control Center.")
		}
	}

	// MARK: - Lifecycle

	private func watchForeground(for operation: Toggle.Operation) {
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
				guard let self, self.pending == operation else { return }
				self.log("Zag Store active again")
				// The callback normally arrives within a moment of activation.
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				if self.pending == operation { self.complete(operation, .noResponse) }
			}
		})
	}

	private func scheduleTimeout(for operation: Toggle.Operation) {
		timeoutTask?.cancel()
		timeoutTask = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(ZagMobileDataToggle.operationLifetime * 1_000_000_000))
			guard let self, !Task.isCancelled, self.pending == operation else { return }
			self.complete(operation, .timedOut)
		}
	}

	private func endActivity() {
		activity = .idle
		timeoutTask?.cancel()
		followUpTask?.cancel()
		healthWatch = nil
		removeObservers()
	}

	private func removeObservers() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers = []
	}

	// MARK: - Helpers

	private func update(_ change: (inout Toggle.Record) -> Void) {
		var next = record
		change(&next)
		record = next
		if let data = try? JSONEncoder().encode(next) {
			UserDefaults.standard.set(data, forKey: Self.recordKey)
		}
	}

	/// Shows protocol replies in full and anything else by length only.
	private func describe(_ value: String?) -> String {
		guard let value else { return "absent" }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.hasPrefix(Toggle.protocolName), trimmed.count <= 64 { return "\"\(trimmed)\"" }
		return "\(value.count) characters"
	}

	private func networkSummary() -> String {
		let networks = ZagLocalVPNMonitor.shared.physicalNetworks
		let tunnel = ZagLocalVPNMonitor.tunnelInterfaceNames()
		return "Network: \(networks.isEmpty ? "none" : networks.joined(separator: ", ")); LocalDevVPN \(tunnel.isEmpty ? "absent" : "present")"
	}

	private func log(_ text: String) {
		let ms = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
		events.append(Event(milliseconds: ms, text: text))
	}
}

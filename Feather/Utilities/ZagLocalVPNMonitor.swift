import Foundation
import Network
import UIKit

/// Drives the Local VPN indicator from three independent layers:
/// - tunnel: whether the iPhone answers through the LocalDevVPN tunnel;
/// - device service: a connect-only check of the RemotePairing endpoint
///   (10.7.0.1:49152), the first connection every RPPairing session makes;
/// - RPPairing: timestamped results of real sessions (health checks and
///   installations), published by ZagRPPairingCore.
///
/// Nothing depends on Wi-Fi. Probes never overlap, a network change during a
/// probe is never lost, stale results are discarded, and no pairing
/// handshake is ever run just to update the toolbar.
@MainActor
final class ZagLocalVPNMonitor: ObservableObject {
	static let shared = ZagLocalVPNMonitor()

	@Published private(set) var model = ZagDeviceLinkModel()
	@Published private(set) var lastSuccess: Date?
	private(set) var physicalNetworks: [String] = []

	private var scheduler = ZagDeviceProbeScheduler()
	private var probeTask: Task<Void, Never>?
	private var tickTask: Task<Void, Never>?
	private var debounceTask: Task<Void, Never>?
	private var observers: [NSObjectProtocol] = []
	private let pathMonitor = NWPathMonitor()
	private let pathQueue = DispatchQueue(label: "zag.localvpn.path")
	private var started = false
	private var active = true

	private init() {}

	func startIfNeeded() {
		guard !started else { return }
		started = true
		active = UIApplication.shared.applicationState == .active

		observers.append(NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.active = true
				self?.refresh()
			}
		})
		observers.append(NotificationCenter.default.addObserver(
			forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in self?.suspend() }
		})
		observers.append(NotificationCenter.default.addObserver(
			forName: .zagDeviceLinkRecheckRequested, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in self?.refresh() }
		})
		observers.append(NotificationCenter.default.addObserver(
			forName: .zagRPPairingReadinessDidChange, object: nil, queue: .main
		) { [weak self] note in
			guard let readiness = note.object as? ZagRPPairingReadiness else { return }
			Task { @MainActor [weak self] in
				guard let self else { return }
				var next = self.model
				next.pairingEvent(readiness)
				self.apply(next)
				if case .verified(let date) = readiness { self.lastSuccess = date }
				self.scheduleTick()
			}
		})

		// Wi-Fi and cellular changes, and the VPN connecting or disconnecting,
		// arrive as path updates. Bursts are coalesced into one check.
		pathMonitor.pathUpdateHandler = { [weak self] path in
			let networks = Self.physicalNetworks(in: path)
			Task { @MainActor [weak self] in self?.pathChanged(networks) }
		}
		pathMonitor.start(queue: pathQueue)
		if active { refresh() }
	}

	/// Checks now, or right after the probe that is already running.
	func refresh() {
		guard active else { return }
		debounceTask?.cancel()
		tickTask?.cancel()
		// While a real RPPairing session runs, it is the evidence; a second
		// connection would only compete with it.
		if ZagRPPairingCore.shared.isTransportBusy {
			scheduleTick()
			return
		}
		guard let generation = scheduler.request() else { return }
		startProbe(generation)
	}

	/// A redacted report for physical-device testing. Runs one endpoint check
	/// and one legacy lockdown check, unless a real session is active.
	func makeReport(steps: [ZagDiagnosticStep], sessionFailure: String?) async -> String {
		var endpoint: ZagEndpointProbeResult?
		var legacy: ZagDeviceProbeResult?
		if !ZagRPPairingCore.shared.isTransportBusy {
			endpoint = await ZagEndpointProbe.connect()
			legacy = await ZagLockdownProbe.query()
		}
		return ZagDiagnosticReport.make(.init(
			generatedAt: Date(),
			iOSVersion: UIDevice.current.systemVersion,
			deviceModel: UIDevice.current.model,
			physicalNetworks: physicalNetworks,
			tunnelInterfaces: Self.tunnelInterfaceNames(),
			model: model,
			endpointProbe: endpoint,
			legacyLockdownProbe: legacy,
			steps: steps,
			sessionFailure: sessionFailure
		))
	}

	private func pathChanged(_ networks: [String]) {
		physicalNetworks = networks
		var next = model
		next.networkChanged(to: networks.first)
		apply(next)
		guard active else { return }
		debounceTask?.cancel()
		debounceTask = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 300_000_000)
			guard !Task.isCancelled else { return }
			self?.refresh()
		}
	}

	private func suspend() {
		active = false
		debounceTask?.cancel()
		tickTask?.cancel()
		probeTask?.cancel()
		probeTask = nil
		scheduler.cancel()
		var next = model
		next.probeAbandoned()
		apply(next)
	}

	private func startProbe(_ generation: Int) {
		let interfacePresent = !Self.tunnelInterfaceNames().isEmpty
		var next = model
		next.probeStarted()
		apply(next)
		let startedAt = Date()
		probeTask = Task { @MainActor [weak self] in
			let result = await ZagEndpointProbe.connect()
			self?.finishProbe(generation, result: result, interfacePresent: interfacePresent, startedAt: startedAt)
		}
	}

	private func finishProbe(_ generation: Int, result: ZagEndpointProbeResult, interfacePresent: Bool, startedAt: Date) {
		let outcome = scheduler.finish(generation)
		guard outcome.accepted else { return }
		probeTask = nil
		let now = Date()
		var next = model
		next.probeFinished(result, interfacePresent: interfacePresent, startedAt: startedAt, finishedAt: now)
		next.expire(now: now)
		apply(next)
		if case .accepted = result { lastSuccess = now }
		if let queued = outcome.next {
			startProbe(queued)
			return
		}
		scheduleTick()
	}

	private func scheduleTick() {
		tickTask?.cancel()
		let interval = model.pollInterval
		tickTask = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
			guard !Task.isCancelled else { return }
			self?.refresh()
		}
	}

	/// Publishes only real changes, so SwiftUI does not re-render the
	/// toolbar for identical states.
	private func apply(_ next: ZagDeviceLinkModel) {
		if next != model { model = next }
	}

	nonisolated static func physicalNetworks(in path: NWPath) -> [String] {
		path.availableInterfaces.compactMap { interface in
			switch interface.type {
			case .wifi: return "Wi-Fi"
			case .cellular: return "Cellular"
			case .wiredEthernet: return "Wired"
			default: return nil
			}
		}
	}

	static func tunnelInterfaceNames() -> [String] {
		ZagTunnelInterface.current()
			.filter { ZagTunnelInterface.isLocalDevTunnel(name: $0.name, ipv4: $0.ipv4) }
			.map(\.name)
	}
}

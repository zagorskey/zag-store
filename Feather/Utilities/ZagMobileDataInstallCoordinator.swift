import UIKit

/// Wraps user installations with Mobile Data Fix. Supplies the real network
/// state, installer probe, Shortcut, consent and storage to
/// ZagMobileDataInstallFlow, and publishes progress and recovery for the UI.
///
/// Lifecycle: nothing here runs in the background or waits for a callback
/// after termination. Shortcuts is opened only while Zag Store is active.
/// If Zag Store is terminated while Mobile Data may be off, the saved
/// recovery record shows a banner on the next launch; the signed app stays
/// in the Library and nothing installs by itself.
@MainActor
final class ZagMobileDataInstallCoordinator: ObservableObject {
	static let shared = ZagMobileDataInstallCoordinator()

	private static let recoveryKey = "ZagStore.mobileDataFix.recovery.v1"
	private static let automaticKey = "ZagStore.mobileDataFix.automatic.v1"

	@Published private(set) var stage: ZagMobileDataInstallStage = .idle
	@Published private(set) var usingMobileDataFix = false
	@Published private(set) var recovery: ZagMobileDataRecoveryRecord?
	@Published private(set) var recoveryMessage: String?
	@Published private(set) var restoringFromBanner = false
	@Published var consentRequested = false
	/// What the pending consent is for, so the alert names the right action.
	@Published private(set) var consentOperation: Operation = .install
	/// The latest operation's decisions, for RPPairing Diagnostics.
	@Published private(set) var decisionLog: [String] = []

	enum Operation: String {
		case install, uninstall
	}
	/// nil: ask the first time. true: approved. false: switched off in Settings.
	@Published private(set) var automaticHandling: Bool?

	private var consentContinuation: CheckedContinuation<ZagMobileDataConsent, Never>?
	private lazy var flow = ZagMobileDataInstallFlow(environment: makeEnvironment())

	private init() {
		let defaults = UserDefaults.standard
		automaticHandling = defaults.object(forKey: Self.automaticKey) as? Bool
		recovery = defaults.data(forKey: Self.recoveryKey).flatMap { try? JSONDecoder().decode(ZagMobileDataRecoveryRecord.self, from: $0) }
	}

	var isBusy: Bool { flow.isBusy }

	// MARK: - Installation

	/// Runs `install` (the existing installer call) directly, or around
	/// Mobile Data Fix when Mobile Data is blocking it. Throws the
	/// installer's error, or why installation was not started.
	///
	/// When Mobile Data Fix was used, the device's app list is read before
	/// Mobile Data comes back on (it can't be read after), waiting for
	/// `bundleID` to appear. The confirmation step then takes that list with
	/// `takeInventory(jobID:)` instead of querying a refused endpoint.
	///
	/// `cancelRequested` is the job's cancel request: honoured before `off`,
	/// or after it with Mobile Data restored, never once the installer runs.
	func install(jobID: String, bundleID: String? = nil, cancelRequested: @escaping () -> Bool = { false }, _ install: () async throws -> Void) async throws {
		inventorySnapshot = nil
		try await perform(.install, jobID: jobID, cancelRequested: cancelRequested) {
			try await install()
			if self.usingMobileDataFix {
				await self.captureInventory(jobID: jobID, bundleID: bundleID)
			}
		}
	}

	// MARK: - Device list after Mobile Data installs

	private struct InventorySnapshot {
		var jobID: String
		var bundleIDs: Set<String>
		var readAt: Date
	}

	/// How long a captured list stands in for a fresh query.
	static let inventorySnapshotLifetime: TimeInterval = 120
	private var inventorySnapshot: InventorySnapshot?

	/// The device list read during this job's Mobile Data Fix, once. nil
	/// for Wi-Fi installs and other jobs, so they query as before.
	func takeInventory(jobID: String, now: Date = Date()) -> Set<String>? {
		guard let snapshot = inventorySnapshot, snapshot.jobID == jobID,
			  now.timeIntervalSince(snapshot.readAt) < Self.inventorySnapshotLifetime else { return nil }
		inventorySnapshot = nil
		return snapshot.bundleIDs
	}

	private func captureInventory(jobID: String, bundleID: String?) async {
		let check = ZagRPPairingInventoryCheck(env: .init(
			transportBusy: { ZagRPPairingCore.shared.isTransportBusy },
			installedApps: {
				await withCheckedContinuation { continuation in
					do {
						try ZagRPPairingCore.shared.refreshInstalledApps { continuation.resume(returning: $0) }
					} catch {
						continuation.resume(returning: .failure(error))
					}
				}
			},
			sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
			now: { Date() },
			log: { [unowned self] in self.record($0) }
		))
		let outcome = await check.run(bundleID: bundleID, expectInstalled: true, label: "Inventory", start: Date())
		if let list = outcome.list {
			inventorySnapshot = InventorySnapshot(jobID: jobID, bundleIDs: list, readAt: Date())
		} else {
			record("Inventory: device list not read before restoring Mobile Data")
		}
	}

	/// Shared by installation and uninstallation: one flow, one Shortcut
	/// path, one recovery record. Throws the RPPairing operation's own
	/// error, so a failed operation never reports success.
	func perform(_ operation: Operation, jobID: String, cancelRequested: @escaping () -> Bool = { false }, _ body: () async throws -> Void) async throws {
		consentOperation = operation
		decisionLog = []
		record("\(operation.rawValue) \(jobID.prefix(8)) started")
		let outcome = await flow.run(jobID: jobID, cancelRequested: cancelRequested, install: body)
		if outcome.usedMobileDataFix {
			NotificationCenter.default.post(name: .zagDeviceLinkRecheckRequested, object: nil)
		}
		record("Result: \(outcome.installed ? "succeeded" : "failed") (\(outcome.notAttempted.map { "not attempted: \($0)" } ?? (outcome.installError == nil ? "operation succeeded" : "operation failed"))); Mobile Data \(outcome.restoration)")
		usingMobileDataFix = false
		if outcome.restoration == .unconfirmed {
			let done = operation == .install ? "The app was installed" : "The app was removed"
			recoveryMessage = outcome.installed
				? "\(done), but Zag Store couldn't confirm Mobile Data is back on."
				: "Zag Store couldn't confirm Mobile Data is back on."
		}
		if let reason = outcome.notAttempted { throw reason }
		if let error = outcome.installError { throw error }
	}

	// MARK: - Consent

	func setAutomaticHandling(_ enabled: Bool) {
		automaticHandling = enabled
		UserDefaults.standard.set(enabled, forKey: Self.automaticKey)
	}

	func answerConsent(allow: Bool) {
		consentRequested = false
		if allow { setAutomaticHandling(true) }
		guard let continuation = consentContinuation else { return }
		consentContinuation = nil
		continuation.resume(returning: allow ? .allowed : .declined)
	}

	private func requestConsent() async -> ZagMobileDataConsent {
		switch automaticHandling {
		case true?: return .allowed
		case false?: return .disabled
		case nil:
			return await withCheckedContinuation { continuation in
				consentContinuation = continuation
				consentRequested = true
			}
		}
	}

	// MARK: - Recovery

	/// Runs `on` once from the banner, then looks for Mobile Data.
	func restoreFromBanner() {
		guard recovery != nil, !isBusy, !restoringFromBanner else { return }
		restoringFromBanner = true
		recoveryMessage = nil
		Task { @MainActor in
			defer { restoringFromBanner = false }
			let result = await ZagMobileDataToggleController.shared.perform(.on)
			ZagLogger.shared.info("MobileDataFix", "Manual restore: on finished \(result)")
			for delay in ZagMobileDataInstallFlow.restoreDelays {
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				if await mobileDataActive() {
					saveRecord(nil)
					return
				}
			}
			recoveryMessage = "Zag Store still can't confirm Mobile Data is on. Turn it on in Control Center, then tap Done."
		}
	}

	/// The user confirms Mobile Data is sorted out.
	func dismissRecovery() {
		guard !isBusy else { return }
		recoveryMessage = nil
		saveRecord(nil)
	}

	/// Clears the record when the installer port shows Mobile Data on again
	/// (refused through LocalDevVPN), or, without an answer, the system
	/// lists Mobile Data.
	func refreshRecovery() {
		guard recovery != nil, !isBusy, !restoringFromBanner else { return }
		ZagLocalVPNMonitor.shared.startIfNeeded()
		Task { @MainActor in
			guard recovery != nil, !isBusy, !restoringFromBanner, await mobileDataActive() else { return }
			ZagLogger.shared.info("MobileDataFix", "Mobile Data is active again; recovery resolved")
			recoveryMessage = nil
			saveRecord(nil)
		}
	}

	private func mobileDataActive() async -> Bool {
		switch await probeInstaller() {
		case .refused: return Self.tunnelPresent()
		case .reachable: return false
		case .unreachable: return currentNetwork() == .cellular
		}
	}

	// MARK: - Environment

	private func makeEnvironment() -> ZagMobileDataInstallFlow.Environment {
		ZagMobileDataInstallFlow.Environment(
			network: { [unowned self] in
				ZagLocalVPNMonitor.shared.startIfNeeded()
				let interfaces = ZagLocalVPNMonitor.shared.physicalNetworks
				let network = ZagMobileDataNetwork.classify(interfaces)
				self.record("Interfaces [\(interfaces.joined(separator: ", "))] → \(network)")
				return network
			},
			endpoint: { [unowned self] in
				let result = await self.probeInstaller()
				self.record("Installer \(ZagDeviceLink.peerAddress):\(ZagDeviceLink.rsdPort) → \(result)")
				return result
			},
			tunnelPresent: { Self.tunnelPresent() },
			shortcutReady: {
				ZagMobileDataToggle.canRunAutomatically(ZagMobileDataToggleController.shared.record)
					&& !ZagMobileDataToggleController.shared.isBusy
			},
			consent: { [unowned self] in await self.requestConsent() },
			runShortcut: { command in await ZagMobileDataToggleController.shared.perform(command) },
			waitUntilActive: { await Self.waitUntilActive() },
			sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
			now: { Date() },
			loadRecord: { [unowned self] in self.recovery },
			saveRecord: { [unowned self] in self.saveRecord($0) },
			stage: { [unowned self] stage in
				self.stage = stage
				if stage == .disablingMobileData { self.usingMobileDataFix = true }
				if stage == .idle { self.usingMobileDataFix = false }
			},
			log: { [unowned self] in self.record($0) }
		)
	}

	/// Adds an operation step to the decision log and the app log.
	func note(_ line: String) {
		record(line)
	}

	private func record(_ line: String) {
		ZagLogger.shared.info("MobileDataFix", line)
		decisionLog.append(line)
		if decisionLog.count > 40 { decisionLog.removeFirst(decisionLog.count - 40) }
	}

	private func probeInstaller() async -> ZagMobileDataEndpoint {
		switch await ZagEndpointProbe.connect(timeout: 2) {
		case .accepted: return .reachable
		case .failed(.refused): return .refused
		case .failed: return .unreachable
		}
	}

	private static func tunnelPresent() -> Bool {
		ZagTunnelInterface.containsLocalDevTunnel(ZagTunnelInterface.current())
	}

	private func currentNetwork() -> ZagMobileDataNetwork {
		ZagMobileDataNetwork.classify(ZagLocalVPNMonitor.shared.physicalNetworks)
	}

	private func saveRecord(_ record: ZagMobileDataRecoveryRecord?) {
		recovery = record
		if let record, let data = try? JSONEncoder().encode(record) {
			UserDefaults.standard.set(data, forKey: Self.recoveryKey)
		} else {
			UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
		}
	}

	private static func waitUntilActive() async {
		while UIApplication.shared.applicationState != .active {
			for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { break }
		}
	}
}

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
	func install(jobID: String, _ install: () async throws -> Void) async throws {
		let outcome = await flow.run(jobID: jobID, install: install)
		usingMobileDataFix = false
		if outcome.restoration == .unconfirmed {
			recoveryMessage = outcome.installed
				? "The app was installed, but Zag Store couldn't confirm Mobile Data is back on."
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
				if currentNetwork() == .mobileDataOnly {
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

	/// Clears the record when the system shows Mobile Data active again.
	func refreshRecovery() {
		guard recovery != nil, !isBusy, !restoringFromBanner else { return }
		ZagLocalVPNMonitor.shared.startIfNeeded()
		if currentNetwork() == .mobileDataOnly {
			ZagLogger.shared.info("MobileDataFix", "Mobile Data is active again; recovery resolved")
			recoveryMessage = nil
			saveRecord(nil)
		}
	}

	// MARK: - Environment

	private func makeEnvironment() -> ZagMobileDataInstallFlow.Environment {
		ZagMobileDataInstallFlow.Environment(
			network: { [unowned self] in
				ZagLocalVPNMonitor.shared.startIfNeeded()
				return self.currentNetwork()
			},
			endpoint: {
				switch await ZagEndpointProbe.connect(timeout: 2) {
				case .accepted: return .reachable
				case .failed(.refused): return .refused
				case .failed: return .unreachable
				}
			},
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
			log: { ZagLogger.shared.info("MobileDataFix", $0) }
		)
	}

	private func currentNetwork() -> ZagMobileDataNetwork {
		let networks = ZagLocalVPNMonitor.shared.physicalNetworks
		if networks.contains("Wi-Fi") { return .wifi }
		if networks.contains("Cellular") { return networks.count == 1 ? .mobileDataOnly : .other }
		return networks.isEmpty ? .none : .other
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

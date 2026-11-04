import Foundation

// Decides whether an installation needs Mobile Data turned off, and runs
// the OFF → install → ON sequence around the existing installer when it does.
// Foundation only, with every dependency injected, so each path is tested on
// the host. ZagMobileDataInstallCoordinator supplies the real dependencies.
//
// Rules:
// - Wi-Fi, or an installer port that answers: run directly, no Shortcut.
// - The decision rests on the RPPairing failure itself, not on interface
//   lists: Mobile Data Fix is used only when the installer port refuses
//   (os 61) through the LocalDevVPN tunnel and Wi-Fi is absent. That is the
//   Mobile Data block. Other failures keep today's behaviour. It also needs
//   a verified Shortcut and the user's approval.
// - Mobile Data is judged on or off by the same port: refused means on,
//   answering means off. Interface lists are only a fallback when the port
//   gives no answer, because LocalDevVPN makes them unreliable.
// - The recovery record is saved before `off` and kept until Mobile Data is
//   seen on again or the user resolves it.
// - `off` and `on` are each sent at most once per job, never repeated after a
//   lost callback, and `on` only after the installer has returned.
// - An answering port means the installer can be reached. It is not treated
//   as proof that Mobile Data is off; the installer still runs Pair-Verify.

enum ZagMobileDataNetwork: Equatable {
	case wifi
	/// A Mobile Data interface is listed (possibly several).
	case cellular
	/// No physical network listed.
	case none
	case other

	/// Classifies the interface list. Any Wi-Fi wins; any number of cellular
	/// interfaces counts as Mobile Data.
	static func classify(_ interfaces: [String]) -> ZagMobileDataNetwork {
		if interfaces.contains("Wi-Fi") { return .wifi }
		if interfaces.contains("Cellular") { return .cellular }
		return interfaces.isEmpty ? .none : .other
	}
}

enum ZagMobileDataEndpoint: Equatable {
	case reachable
	/// Refused: on Mobile Data this is the block Mobile Data Fix works around.
	case refused
	case unreachable
}

enum ZagMobileDataConsent: Equatable {
	case allowed
	/// "Not Now": ask again next time.
	case declined
	/// Automatic handling switched off in Settings.
	case disabled
}

enum ZagMobileDataInstallStage: Equatable {
	case idle
	case checkingConnection
	case disablingMobileData
	case connecting
	case installing
	case restoringMobileData
}

enum ZagMobileDataRestoration: Equatable {
	/// This job did not turn Mobile Data off.
	case notChanged
	/// Mobile Data was seen on again.
	case restored
	/// Zag Store could not confirm Mobile Data is back on.
	case unconfirmed
}

struct ZagMobileDataRecoveryRecord: Codable, Equatable {
	var jobID: String
	var offRequestedAt: Date
	var onRequestedAt: Date?
}

enum ZagMobileDataInstallError: LocalizedError, Equatable {
	case alreadyRunning
	case shortcutNotReady
	case consentDeclined
	case automaticDisabled
	case cancelled
	case connectionUnavailable

	var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			return "Another installation or removal is in progress. Try again when it finishes."
		case .shortcutNotReady:
			return "Installing or removing apps over Mobile Data needs Mobile Data Fix. Set it up in Settings → Installation → Apply Mobile Data Fix, or connect to Wi-Fi."
		case .consentDeclined:
			return "This needs Mobile Data turned off briefly. Connect to Wi-Fi, or allow Mobile Data Fix and try again."
		case .automaticDisabled:
			return "Automatic Mobile Data handling is off. Turn off Mobile Data in Control Center, or turn the setting back on in Mobile Data Fix, then try again."
		case .cancelled:
			return "Cancelled. Nothing was installed or removed."
		case .connectionUnavailable:
			return "Zag Store couldn't reach the installation service after asking to turn Mobile Data off. Nothing was installed or removed."
		}
	}
}

struct ZagMobileDataInstallOutcome {
	/// Why the installer was not started, if it wasn't.
	var notAttempted: ZagMobileDataInstallError?
	/// The installer's own error, if it ran and failed.
	var installError: Error?
	var restoration: ZagMobileDataRestoration
	var usedMobileDataFix: Bool

	var installed: Bool { notAttempted == nil && installError == nil }
}

@MainActor
final class ZagMobileDataInstallFlow {
	struct Environment {
		var network: () async -> ZagMobileDataNetwork
		var endpoint: () async -> ZagMobileDataEndpoint
		/// Whether the LocalDevVPN tunnel interface exists.
		var tunnelPresent: () -> Bool
		var shortcutReady: () -> Bool
		var consent: () async -> ZagMobileDataConsent
		var runShortcut: (ZagMobileDataToggle.Command) async -> ZagMobileDataToggle.Completion
		/// Returns once Zag Store is in the foreground; Shortcuts can only
		/// be opened from there.
		var waitUntilActive: () async -> Void
		var sleep: (TimeInterval) async -> Void
		var now: () -> Date
		var loadRecord: () -> ZagMobileDataRecoveryRecord?
		var saveRecord: (ZagMobileDataRecoveryRecord?) -> Void
		var stage: (ZagMobileDataInstallStage) -> Void
		var log: (String) -> Void
	}

	/// Waits between reachability checks after `off` (about 10 s in total).
	static let connectDelays: [TimeInterval] = [0.5, 1.5, 3, 5]
	/// Waits between checks for Mobile Data after `on` (about 6 s in total).
	static let restoreDelays: [TimeInterval] = [1, 2, 3]

	private let env: Environment
	private(set) var isBusy = false

	init(environment: Environment) {
		env = environment
	}

	func run(jobID: String, install: () async throws -> Void) async -> ZagMobileDataInstallOutcome {
		guard !isBusy else {
			env.log("Rejected: another installation is preparing")
			return ZagMobileDataInstallOutcome(notAttempted: .alreadyRunning, restoration: .notChanged, usedMobileDataFix: false)
		}
		isBusy = true
		defer {
			isBusy = false
			env.stage(.idle)
		}

		env.stage(.checkingConnection)
		let network = await env.network()
		if network == .wifi {
			env.log("Wi-Fi connected: installing directly")
			return await installDirectly(install)
		}
		let endpoint = await env.endpoint()
		let tunnel = env.tunnelPresent()
		guard endpoint == .refused, tunnel else {
			env.log("Decision: direct (network \(network), LocalDevVPN \(tunnel ? "present" : "absent"), installer \(endpoint))")
			return await installDirectly(install)
		}
		env.log("Decision: Mobile Data Fix (network \(network), LocalDevVPN present, installer refused)")

		// The refusal shows Mobile Data is on, so any earlier record is resolved.
		if let earlier = env.loadRecord() {
			env.log("Earlier record \(earlier.jobID) resolved: Mobile Data is active")
			env.saveRecord(nil)
		}
		guard env.shortcutReady() else {
			env.log("Mobile Data is blocking the installer; Mobile Data Fix is not verified")
			return notAttempted(.shortcutNotReady)
		}
		switch await env.consent() {
		case .allowed: break
		case .declined: return notAttempted(.consentDeclined)
		case .disabled: return notAttempted(.automaticDisabled)
		}
		if Task.isCancelled { return notAttempted(.cancelled) }

		// Saved before `off`, so a relaunch knows Mobile Data may be off.
		env.saveRecord(ZagMobileDataRecoveryRecord(jobID: jobID, offRequestedAt: env.now()))
		env.stage(.disablingMobileData)
		await env.waitUntilActive()
		let off = await env.runShortcut(.off)
		env.log("off finished: \(off)")

		env.stage(.connecting)
		let reachable = await waitForInstaller()
		env.log(reachable ? "Installer reachable" : "Installer still unreachable")

		if off == .cancelled || Task.isCancelled {
			let restoration = await restore(installerReachable: reachable)
			return ZagMobileDataInstallOutcome(notAttempted: .cancelled, restoration: restoration, usedMobileDataFix: true)
		}
		guard reachable else {
			let restoration = await restore(installerReachable: false)
			return ZagMobileDataInstallOutcome(notAttempted: .connectionUnavailable, restoration: restoration, usedMobileDataFix: true)
		}

		env.stage(.installing)
		var installError: Error?
		do {
			try await install()
			env.log("Installer reported success")
		} catch {
			installError = error
			env.log("Installer reported failure")
		}
		// Only now that the installer has returned is Mobile Data restored.
		let restoration = await restore(installerReachable: true)
		return ZagMobileDataInstallOutcome(installError: installError, restoration: restoration, usedMobileDataFix: true)
	}

	// MARK: - Steps

	private func installDirectly(_ install: () async throws -> Void) async -> ZagMobileDataInstallOutcome {
		env.stage(.installing)
		do {
			try await install()
			return ZagMobileDataInstallOutcome(restoration: .notChanged, usedMobileDataFix: false)
		} catch {
			return ZagMobileDataInstallOutcome(installError: error, restoration: .notChanged, usedMobileDataFix: false)
		}
	}

	private func notAttempted(_ reason: ZagMobileDataInstallError) -> ZagMobileDataInstallOutcome {
		env.log("Not installed: \(reason)")
		return ZagMobileDataInstallOutcome(notAttempted: reason, restoration: .notChanged, usedMobileDataFix: false)
	}

	private func waitForInstaller() async -> Bool {
		for delay in Self.connectDelays {
			await env.sleep(delay)
			if Task.isCancelled { return false }
			if await env.endpoint() == .reachable { return true }
		}
		return false
	}

	/// Sends `on` at most once, and only when Mobile Data may be off because
	/// of this job. Keeps the recovery record unless Mobile Data is seen on.
	private func restore(installerReachable: Bool) async -> ZagMobileDataRestoration {
		if !installerReachable, await mobileDataActive() {
			// The installer is still refused, so `off` changed nothing.
			env.log("Mobile Data is still on; nothing to restore")
			env.saveRecord(nil)
			return .notChanged
		}

		env.stage(.restoringMobileData)
		await env.waitUntilActive()
		if var record = env.loadRecord() {
			record.onRequestedAt = env.now()
			env.saveRecord(record)
		}
		let on = await env.runShortcut(.on)
		env.log("on finished: \(on)")
		for delay in Self.restoreDelays {
			await env.sleep(delay)
			if await mobileDataActive() {
				env.log("Mobile Data is active again")
				env.saveRecord(nil)
				return .restored
			}
		}
		env.log("Could not confirm Mobile Data is on; keeping the recovery record")
		return .unconfirmed
	}

	/// Refused through the tunnel: Mobile Data is on. Answering: it is off.
	/// No answer at all: fall back to the interface list.
	private func mobileDataActive() async -> Bool {
		switch await env.endpoint() {
		case .refused: return env.tunnelPresent()
		case .reachable: return false
		case .unreachable: return await env.network() == .cellular
		}
	}
}

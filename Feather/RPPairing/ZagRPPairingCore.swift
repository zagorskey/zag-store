import Foundation
import Combine
import OSLog
import UIKit
import UserNotifications

private let zagRPPairingLog = Logger(subsystem: "com.cwd43.gu29.rppairing", category: "Transport")

private func zagGate2Callback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveGate2(code: code, message: text)
	}
}

private func zagGate4Callback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveGate4(code: code, message: text)
	}
}

private func zagGate4UninstallCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveGate4Uninstall(code: code, message: text)
	}
}

private func zagInstalledAppIconsCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveInstalledAppIcons(code: code, message: text)
	}
}

private func zagInstalledAppsCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveInstalledApps(code: code, message: text)
	}
}

private func zagHouseArrestPairingInstallCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveHouseArrestPairingInstall(code: code, message: text)
	}
}

private func zagHouseArrestCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveHouseArrest(code: code, message: text)
	}
}

private func zagRPPairingCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receive(code: code, message: text)
	}
}

@MainActor
final class ZagRPPairingCore: ObservableObject {
	static let shared = ZagRPPairingCore()

	enum State: Equatable {
		case idle
		case starting
		case advertising
		case connected
		case pin(String)
		case paired(name: String, model: String, udid: String)
		case failed(String)
	}

	@Published private(set) var state: State = .idle

	enum InstalledAppsState: Equatable {
		case idle
		case refreshing
		case loaded(Int)
		case failed(String)
	}

	struct InstalledAppInfo: Equatable {
		let bundleID: String
		let version: String
		let build: String
		let name: String
		let executable: String
		let minimumOSVersion: String
		let applicationType: String
		let signerIdentity: String
	}

	@Published private(set) var installedBundleIDs: Set<String> = []
	@Published private(set) var installedApps: [String: InstalledAppInfo] = [:]
	@Published private(set) var installedAppsDebugKeys: String?
	@Published private(set) var installedAppsState: InstalledAppsState = .idle
	@Published private(set) var installedAppIconURLs: [String: URL] = [:]
	@Published private(set) var installedAppIconsRefreshing = false
	@Published private(set) var houseArrestRunning = false
	@Published private(set) var houseArrestBundleID: String?
	@Published private(set) var houseArrestDocuments: [String] = []
	@Published private(set) var houseArrestError: String?
	@Published private(set) var houseArrestPairingInstallRunning = false
	@Published private(set) var houseArrestPairingInstallStatus: String?
	@Published private(set) var houseArrestPairingInstallError: String?
	private var pendingInstalledApps: [String: InstalledAppInfo] = [:]

	private var installedAppsCompletion: ((Result<Set<String>, Error>) -> Void)?
	// All native RPPairing workers open their own socket. Never overlap them.
	// Gate2 is queued behind an automatic inventory request for diagnostics.
	private var transportOwner: String?
	/// True while any native RPPairing worker owns the transport.
	var isTransportBusy: Bool { transportOwner != nil }
	/// Timed, redacted steps of the latest health check, for the report.
	private(set) var gate2Steps: [ZagDiagnosticStep] = []
	private(set) var gate2Failure: String?
	private var gate2StartedAt = Date()
	private var pendingGate2Endpoint: ZagRPPairingEndpoint?
	/// The endpoint of the current or most recent health check. Fixed when a
	/// check starts; every check without an explicit endpoint uses LocalDevVPN.
	@Published private(set) var gate2Endpoint: ZagRPPairingEndpoint = .localDevVPN
	private func acquireTransport(_ operation: String) -> Bool {
		guard transportOwner == nil else {
			ZagLogger.shared.warning("RPPairing", "Transport busy | requested=\(operation) owner=\(transportOwner ?? "unknown")")
			return false
		}
		transportOwner = operation
		ZagLogger.shared.info("RPPairing", "Transport acquired | owner=\(operation)")
		return true
	}
	private func releaseTransport(_ operation: String) {
		guard transportOwner == operation else { return }
		transportOwner = nil
		ZagLogger.shared.info("RPPairing", "Transport released | owner=\(operation)")
		if let endpoint = pendingGate2Endpoint {
			pendingGate2Endpoint = nil
			gate2State = .idle
			startGate2Probe(endpoint: endpoint)
		}
	}

	enum Gate2State: Equatable {
		case idle
		case starting
		case lockdown(String)
		case pairing(String)
		case pairRecord(String)
		case coreDevice(String)
		case rsd(String)
		case deviceInfo(name: String, model: String, version: String, build: String)
		case installationProxy(String)
		case installedApps(userAppCount: Int, zagStoreFound: Bool)
		case afc(String)
		case stagingWrite(String)
		case stagingVerify(String)
		case complete(name: String, model: String, version: String, build: String, userAppCount: Int, zagStoreFound: Bool)
		case failed(String)
	}

	@Published private(set) var gate2State: Gate2State = .idle

	enum Gate4State: Equatable {
		case idle
		case starting
		case pairVerified
		case tunnel
		case rsd
		case installing
		case uploading(Int)
		case staged
		case upgradeSubmitted
		case progress(Int)
		case complete
		case failed(String)
	}

	@Published private(set) var gate4State: Gate4State = .idle
	@Published private(set) var gate4SelfUpdateCommandSent = false
	/// Callbacks received for the current or most recent Gate4 attempt, in
	/// order. Used to tell whether a failure happened before the Upgrade request.
	private(set) var gate4AttemptEvents: [ZagGate4Event] = []
	@Published private(set) var gate4LastEvent = "No Gate4 activity this session"
	private static let gate4HistoryKey = "ZagStore.Gate4LastRecordedEvent.v1"
	var gate4PreviousEvent: String {
		UserDefaults.standard.string(forKey: Self.gate4HistoryKey) ?? "No recorded Gate4 attempt"
	}
	private func recordGate4Event(_ event: String) {
		gate4LastEvent = event
		UserDefaults.standard.set(
			ISO8601DateFormatter().string(from: Date()) + " | " + event,
			forKey: Self.gate4HistoryKey
		)
	}
	private var gate4Completion: ((Result<Void, Error>) -> Void)?
	private var gate4Progress: ((Int) -> Void)?
	/// Retries apply only to user installs that opt in, and only to failures
	/// before installation began on the device (see ZagRPPairingFailure).
	private var gate4RetryPlan = ZagGate4RetryPlan()
	private var gate4RetryEnabled = false
	private var gate4StagedIPA: URL?
	private var gate4DeviceIP = ZagDeviceLink.peerAddress
	/// Callback codes that mean the device has started changing state.
	private static let gate4InstallationCodes: Set<Int32> = [205, 206, 208, 209, 210]
	private var gate4UninstallCompletion: ((Result<Void, Error>) -> Void)?
	private var gate4UninstallRunning = false
	private var gate2DeviceInfo: (name: String, model: String, version: String, build: String)?
	private var gate2LastAppResult: (Int, Bool)?
	private let advertiser = ZagPairableHostAdvertiser()
	private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

	static var version: String {
		guard let pointer = zag_rppairing_core_version() else { return "Unavailable" }
		defer { zag_rppairing_string_free(pointer) }
		return String(cString: pointer)
	}

	var isRunning: Bool {
		switch state {
		case .starting, .advertising, .connected, .pin: return true
		default: return false
		}
	}

	var isGate2Running: Bool {
		switch gate2State {
		case .starting, .lockdown, .pairing, .pairRecord, .coreDevice, .rsd, .deviceInfo, .installationProxy, .installedApps, .afc, .stagingWrite, .stagingVerify:
			return true
		default:
			return false
		}
	}


	var isGate4Running: Bool {
		switch gate4State {
		case .starting, .pairVerified, .tunnel, .rsd, .installing, .uploading, .staged, .upgradeSubmitted, .progress: return true
		default: return false
		}
	}

	func installGate4IPA(
		at sourceURL: URL,
		deviceIP: String = ZagDeviceLink.peerAddress,
		retryTransientFailures: Bool = false,
		progress: ((Int) -> Void)? = nil,
		completion: ((Result<Void, Error>) -> Void)? = nil
	) throws {
		guard !isGate4Running, acquireTransport("Gate4 install") else {
			throw Gate4InstallError.alreadyRunning
		}
		_ = gate4RetryPlan.begin()
		gate4RetryEnabled = retryTransientFailures
		gate4DeviceIP = deviceIP
		gate4AttemptEvents = []
		gate4Completion = completion
		gate4Progress = progress
		let localURL: URL
		do {
			let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
				.appendingPathComponent("ZagStore/Gate4", isDirectory: true)
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			localURL = directory.appendingPathComponent("gate4-test.ipa")
			try? FileManager.default.removeItem(at: localURL)
			let scoped = sourceURL.startAccessingSecurityScopedResource()
			defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
			try FileManager.default.copyItem(at: sourceURL, to: localURL)
		} catch {
			// No worker was started, so no callback will ever run these.
			// The caller reports the thrown error instead.
			releaseTransport("Gate4 install")
			gate4RetryPlan.end()
			gate4Completion = nil
			gate4Progress = nil
			throw error
		}

		ZagLogger.shared.info("RPPairing", "Gate4 install starting | deviceIP=\(deviceIP) | ipa=\(sourceURL.lastPathComponent)")
		gate4StagedIPA = localURL
		gate4State = .starting
		recordGate4Event("IPA staged; requesting native Gate4 worker startup")
		if !startGate4Worker(deviceIP: deviceIP, ipa: localURL) {
			releaseTransport("Gate4 install")
			gate4RetryPlan.end()
			recordGate4Event("Native Gate4 worker failed to start")
			ZagLogger.shared.error("RPPairing", gate4LastEvent)
			let error = Gate4InstallError.couldNotStart
			gate4State = .failed(error.localizedDescription)
			gate4Completion = nil
			gate4Progress = nil
			throw error
		}
		recordGate4Event("Native Gate4 worker accepted startup; awaiting callback")
		ZagLogger.shared.info("RPPairing", gate4LastEvent)
	}

	private func startGate4Worker(deviceIP: String, ipa: URL) -> Bool {
		deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				ipa.path.withCString { ipaPath in
					zag_gate4_install(ip, pairingPath, ipaPath, zagGate4Callback)
				}
			}
		}
	}

	/// Runs the same staged IPA again after a transient, pre-installation
	/// failure. The transport stays owned throughout, so nothing else can
	/// start in between, and the caller still receives exactly one result.
	private func retryGate4(after delay: TimeInterval, kind: ZagRPPairingFailureKind, message: String) {
		guard let ipa = gate4StagedIPA else { return }
		recordGate4Event("Gate4 \(kind) before installation; retry \(gate4RetryPlan.retriesUsed) in \(Int(delay)) s: \(message)")
		ZagLogger.shared.warning("RPPairing", gate4LastEvent)
		gate4State = .starting
		NotificationCenter.default.post(name: .zagDeviceLinkRecheckRequested, object: nil)
		Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			// Retry only while the tunnel is plausibly there. With no tunnel
			// interface and no answer, LocalDevVPN is off: fail now rather than
			// spend another full connection timeout.
			let tunnel = ZagTunnelInterface.containsLocalDevTunnel(ZagTunnelInterface.current())
			let probe = await ZagEndpointProbe.connect(host: self?.gate4DeviceIP ?? ZagDeviceLink.peerAddress, timeout: 2)
			guard let self, self.gate4RetryPlan.active else { return }
			if ZagDeviceLinkModel.tunnelIsDown(probe, interfacePresent: tunnel) {
				self.gate4RetryPlan.end()
				self.receiveGate4(code: -4, message: message)
				return
			}
			self.gate4AttemptEvents = []
			if !self.startGate4Worker(deviceIP: self.gate4DeviceIP, ipa: ipa) {
				self.gate4RetryPlan.end()
				self.receiveGate4(code: -4, message: Gate4InstallError.couldNotStart.localizedDescription)
			}
		}
	}

	private func publishReadiness(_ readiness: ZagRPPairingReadiness) {
		NotificationCenter.default.post(name: .zagRPPairingReadinessDidChange, object: readiness)
	}

	/// Health checks on an experimental endpoint never change the toolbar.
	private func publishGate2Readiness(_ readiness: ZagRPPairingReadiness) {
		guard gate2Endpoint.publishesReadiness else { return }
		publishReadiness(readiness)
	}

	fileprivate func receiveGate4(code: Int32, message: String) {
		gate4AttemptEvents.append(ZagGate4Event(code: code, message: message))
		recordGate4Event("Gate4 callback \(code): \(message)")
		// Record native installation stages for diagnostics.
		if code == 206 {
			ZagLogger.shared.info("RPPairing", "Gate4 install progress: \(message)%")
		} else {
			ZagLogger.shared.info("RPPairing", "Gate4 callback stage=\(code) detail=\(message)")
		}
		switch code {
		case 201: gate4State = .starting
		case 202:
			gate4State = .pairVerified
			publishReadiness(.verified(Date()))
		case 203: gate4State = .tunnel
		case 204: gate4State = .rsd
		case 205: gate4State = .installing
		case 208:
			if let percent = Int(message), (0...100).contains(percent) {
				gate4State = .uploading(percent)
			}
		case 209: gate4State = .staged
		case 210:
			gate4SelfUpdateCommandSent = true
			gate4State = .upgradeSubmitted
		case 206:
			if let percent = Int(message), (0...100).contains(percent) {
				gate4State = .progress(percent)
				gate4Progress?(percent)
			}
		case 207:
			ZagLogger.shared.info("RPPairing", "Gate4 install completed")
			gate4State = .complete
			gate4RetryPlan.end()
			releaseTransport("Gate4 install")
			gate4Completion?(.success(()))
			gate4Completion = nil
			gate4Progress = nil
		case -4:
			let installationStarted = gate4AttemptEvents.contains { Self.gate4InstallationCodes.contains($0.code) }
			let kind = ZagRPPairingFailure.classify(message, installationStarted: installationStarted)
			if gate4RetryEnabled, let delay = gate4RetryPlan.delayAfterFailure(kind) {
				retryGate4(after: delay, kind: kind, message: message)
				return
			}
			gate4RetryPlan.end()
			if kind != .installation && kind != .other { publishReadiness(.failed(kind, Date())) }
			releaseTransport("Gate4 install")
			gate4SelfUpdateCommandSent = false
			ZagLogger.shared.error("RPPairing", "Gate4 install failed (\(kind)): \(message)")
			gate4State = .failed(message)
			let error: Gate4InstallError = gate4RetryEnabled
				? .classifiedFailure(message, kind)
				: .installFailed(message)
			gate4Completion?(.failure(error))
			gate4Completion = nil
			gate4Progress = nil
		default: break
		}
	}

	/// A user-initiated exit is allowed only once the exact self-update
	/// Upgrade request has been transmitted. It is not proof of acceptance.
	/// Caller may terminate the process only after this record is flushed.
	func recordConfirmedSelfUpdateClose() -> Bool {
		guard gate4SelfUpdateCommandSent, isGate4Running else { return false }
		recordGate4Event("User chose to close Zag Store after Upgrade transmission")
		return UserDefaults.standard.synchronize()
	}


	func uninstallGate4App(
		bundleID: String,
		deviceIP: String = "10.7.0.1",
		completion: @escaping (Result<Void, Error>) -> Void
	) throws {
		guard !gate4UninstallRunning else {
			throw Gate4UninstallError.alreadyRunning
		}
		guard !bundleID.isEmpty else {
			throw Gate4UninstallError.invalidBundleID
		}
		guard acquireTransport("Gate4 uninstall") else { throw Gate4UninstallError.alreadyRunning }

		gate4UninstallRunning = true
		gate4UninstallCompletion = completion
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				bundleID.withCString { bundleID in
					zag_gate4_uninstall(ip, pairingPath, bundleID, zagGate4UninstallCallback)
				}
			}
		}
		if !started {
			releaseTransport("Gate4 uninstall")
			gate4UninstallRunning = false
			gate4UninstallCompletion = nil
			throw Gate4UninstallError.couldNotStart
		}
	}

	fileprivate func receiveGate4Uninstall(code: Int32, message: String) {
		switch code {
		case 307:
			releaseTransport("Gate4 uninstall")
			gate4UninstallRunning = false
			let completion = gate4UninstallCompletion
			gate4UninstallCompletion = nil
			completion?(.success(()))
		case -5:
			releaseTransport("Gate4 uninstall")
			gate4UninstallRunning = false
			let completion = gate4UninstallCompletion
			gate4UninstallCompletion = nil
			completion?(.failure(Gate4UninstallError.uninstallFailed(message)))
		default:
			break
		}
	}

	func installPairingFileInSideStore(
		bundleID: String = "com.SideStore.SideStore",
		deviceIP: String = "10.7.0.1"
	) throws {
		guard !houseArrestPairingInstallRunning else { return }
		guard pairingFileExists else { throw InstalledAppsError.notPaired }
		guard acquireTransport("SideStore pairing transfer") else { throw InstalledAppsError.alreadyRunning }

		houseArrestPairingInstallRunning = true
		houseArrestPairingInstallStatus = "Starting…"
		houseArrestPairingInstallError = nil
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				bundleID.withCString { bundleID in
					zag_house_arrest_install_pairing_file(ip, pairingPath, bundleID, zagHouseArrestPairingInstallCallback)
				}
			}
		}
		if !started {
			releaseTransport("SideStore pairing transfer")
			houseArrestPairingInstallRunning = false
			houseArrestPairingInstallError = "The pairing file transfer could not be started."
		}
	}

	fileprivate func receiveHouseArrestPairingInstall(code: Int32, message: String) {
		switch code {
		case 611, 612, 613, 614, 615:
			houseArrestPairingInstallRunning = true
			houseArrestPairingInstallStatus = message
		case 616:
			releaseTransport("SideStore pairing transfer")
			houseArrestPairingInstallRunning = false
			houseArrestPairingInstallStatus = message
			ZagLogger.shared.info("RPPairing", "SideStore pairing transfer complete | \(message)")
		case -9:
			releaseTransport("SideStore pairing transfer")
			houseArrestPairingInstallRunning = false
			houseArrestPairingInstallError = message
			ZagLogger.shared.error("RPPairing", "SideStore pairing transfer failed: \(message)")
		default:
			break
		}
	}

	func listSharedDocuments(
		bundleID: String,
		deviceIP: String = "10.7.0.1"
	) throws {
		guard !houseArrestRunning else { return }
		guard pairingFileExists else { throw InstalledAppsError.notPaired }
		guard !bundleID.isEmpty else { return }
		guard acquireTransport("House Arrest") else { throw InstalledAppsError.alreadyRunning }

		houseArrestRunning = true
		houseArrestBundleID = nil
		houseArrestDocuments = []
		houseArrestError = nil
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				bundleID.withCString { bundleID in
					zag_house_arrest_list_documents(ip, pairingPath, bundleID, zagHouseArrestCallback)
				}
			}
		}
		if !started {
			releaseTransport("House Arrest")
			houseArrestRunning = false
			houseArrestError = "The House Arrest probe could not be started."
		}
	}

	fileprivate func receiveHouseArrest(code: Int32, message: String) {
		switch code {
		case 601:
			houseArrestRunning = true
		case 602:
			houseArrestBundleID = message
		case 603, 604:
			ZagLogger.shared.info("RPPairing", "House Arrest | \(message)")
		case 605:
			houseArrestDocuments = message.isEmpty ? [] : message.split(separator: "\t").map(String.init)
		case 606:
			releaseTransport("House Arrest")
			houseArrestRunning = false
			ZagLogger.shared.info("RPPairing", "House Arrest probe complete | \(message)")
		case -8:
			releaseTransport("House Arrest")
			houseArrestRunning = false
			houseArrestError = message
			ZagLogger.shared.error("RPPairing", "House Arrest probe failed: \(message)")
		default:
			break
		}
	}

	func refreshInstalledApps(
		deviceIP: String = "10.7.0.1",
		completion: ((Result<Set<String>, Error>) -> Void)? = nil
	) throws {
		guard installedAppsState != .refreshing else { throw InstalledAppsError.alreadyRunning }
		guard pairingFileExists else { throw InstalledAppsError.notPaired }
		guard acquireTransport("Installed apps inventory") else { throw InstalledAppsError.alreadyRunning }

		pendingInstalledApps.removeAll(keepingCapacity: true)
		installedAppsCompletion = completion
		ZagLogger.shared.info("RPPairing", "Installed-app inventory refresh starting | deviceIP=\(deviceIP)")
		installedAppsState = .refreshing
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				zag_installed_apps(ip, pairingPath, zagInstalledAppsCallback)
			}
		}
		if !started {
			releaseTransport("Installed apps inventory")
			installedAppsState = .failed(InstalledAppsError.couldNotStart.localizedDescription)
			installedAppsCompletion = nil
			throw InstalledAppsError.couldNotStart
		}
	}

	fileprivate func receiveInstalledApps(code: Int32, message: String) {
		switch code {
		case 401:
			pendingInstalledApps.removeAll(keepingCapacity: true)
			installedAppsState = .refreshing
		case 402:
			let fields = message.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
			guard let bundleID = fields.first, !bundleID.isEmpty else { break }
			let info = InstalledAppInfo(
				bundleID: bundleID,
				version: fields.indices.contains(1) ? fields[1] : "",
				build: fields.indices.contains(2) ? fields[2] : "",
				name: fields.indices.contains(3) ? fields[3] : "",
				executable: fields.indices.contains(4) ? fields[4] : "",
				minimumOSVersion: fields.indices.contains(5) ? fields[5] : "",
				applicationType: fields.indices.contains(6) ? fields[6] : "",
				signerIdentity: fields.indices.contains(7) ? fields[7] : ""
			)
			pendingInstalledApps[bundleID] = info
		case 404:
			installedAppsDebugKeys = message
			ZagLogger.shared.info("RPPairing", "Installed-app metadata keys | \(message)")
		case 403:
			releaseTransport("Installed apps inventory")
			ZagLogger.shared.info("RPPairing", "Installed-app inventory loaded | count=\(Int(message) ?? pendingInstalledApps.count)")
			installedApps = pendingInstalledApps
			installedBundleIDs = Set(installedApps.keys)
			installedAppsState = .loaded(Int(message) ?? installedBundleIDs.count)
			let completion = installedAppsCompletion
			installedAppsCompletion = nil
			completion?(.success(installedBundleIDs))
		case -6:
			releaseTransport("Installed apps inventory")
			ZagLogger.shared.error("RPPairing", "Installed-app inventory failed: \(message)")
			pendingInstalledApps.removeAll(keepingCapacity: true)
			installedAppsState = .failed(message)
			let completion = installedAppsCompletion
			installedAppsCompletion = nil
			completion?(.failure(InstalledAppsError.refreshFailed(message)))
		default:
			break
		}
	}

	func refreshInstalledAppIcons(
		bundleIDs: [String],
		deviceIP: String = "10.7.0.1"
	) throws {
		guard !installedAppIconsRefreshing else { return }
		guard pairingFileExists else { throw InstalledAppsError.notPaired }

		let requested = Array(Set(bundleIDs.filter { !$0.isEmpty })).sorted()
		guard !requested.isEmpty else { return }
		guard acquireTransport("Installed app icons") else { throw InstalledAppsError.alreadyRunning }

		let directory = FileManager.default.urls(
			for: .cachesDirectory,
			in: .userDomainMask
		).first!
			.appendingPathComponent("ZagStore/InstalledAppIcons", isDirectory: true)
		do {
			try FileManager.default.createDirectory(
				at: directory,
				withIntermediateDirectories: true
			)
		} catch {
			releaseTransport("Installed app icons")
			throw error
		}

		installedAppIconsRefreshing = true
		let joined = requested.joined(separator: "\t")
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				joined.withCString { bundleIDs in
					directory.path.withCString { outputDirectory in
						zag_installed_app_icons(
							ip,
							pairingPath,
							bundleIDs,
							outputDirectory,
							zagInstalledAppIconsCallback
						)
					}
				}
			}
		}

		if !started {
			releaseTransport("Installed app icons")
			installedAppIconsRefreshing = false
			throw InstalledAppsError.couldNotStart
		}
	}

	fileprivate func receiveInstalledAppIcons(code: Int32, message: String) {
		switch code {
		case 501:
			installedAppIconsRefreshing = true
		case 502:
			let fields = message.split(
				separator: "\t",
				maxSplits: 1,
				omittingEmptySubsequences: false
			).map(String.init)
			guard fields.count == 2, !fields[0].isEmpty else { break }
			installedAppIconURLs[fields[0]] = URL(fileURLWithPath: fields[1])
		case 503, -7:
			releaseTransport("Installed app icons")
			installedAppIconsRefreshing = false
		default:
			break
		}
	}

	func isInstalled(bundleID: String) -> Bool {
		installedBundleIDs.contains(bundleID)
	}

	func installedAppInfo(bundleID: String) -> InstalledAppInfo? {
		installedApps[bundleID]
	}

	func startGate2Probe(endpoint: ZagRPPairingEndpoint = .localDevVPN) {
		guard !isGate2Running else { return }
		let deviceIP = endpoint.address
		guard acquireTransport("Gate2 health probe") else {
			// Manual diagnostics should run after background inventory finishes.
			pendingGate2Endpoint = endpoint
			gate2State = .starting
			ZagLogger.shared.info("RPPairing", "Gate2 health probe queued behind active transport")
			return
		}
		ZagLogger.shared.info("RPPairing", "Gate2 health probe starting | deviceIP=\(deviceIP)")
		gate2Endpoint = endpoint
		gate2Steps = []
		gate2Failure = nil
		gate2StartedAt = Date()
		gate2State = .starting
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				zag_gate2_probe(ip, pairingPath, zagGate2Callback)
			}
		}
		if !started {
			releaseTransport("Gate2 health probe")
			gate2State = .failed("The Gate 2 probe could not be started.")
		}
	}

	fileprivate func receiveGate2(code: Int32, message: String) {
		recordGate2Step(code: code, message: message)
		switch code {
		case 101:
			gate2State = .starting
		case 102:
			gate2State = .lockdown(message)
		case 103:
			gate2State = .pairing(message)
		case 104:
			gate2State = .pairRecord(message)
			// The iPhone accepted the saved credentials over the real transport.
			publishGate2Readiness(.verified(Date()))
		case 105:
			gate2State = .coreDevice(message)
		case 106:
			gate2State = .rsd(message)
		case 107:
			let fields = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
			let info = (
				name: fields.indices.contains(0) ? fields[0] : "This iPhone",
				model: fields.indices.contains(1) ? fields[1] : "",
				version: fields.indices.contains(2) ? fields[2] : "",
				build: fields.indices.contains(3) ? fields[3] : ""
			)
			gate2DeviceInfo = info
			gate2State = .deviceInfo(name: info.name, model: info.model, version: info.version, build: info.build)
		case 108:
			gate2State = .installationProxy(message)
		case 109:
			let fields = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
			let result = (
				fields.indices.contains(0) ? (Int(fields[0]) ?? 0) : 0,
				fields.indices.contains(1) ? fields[1] == "true" : false
			)
			gate2LastAppResult = result
			gate2State = .installedApps(userAppCount: result.0, zagStoreFound: result.1)
		case 110:
			gate2State = .afc(message)
		case 111:
			gate2State = .stagingWrite(message)
		case 112:
			gate2State = .stagingVerify(message)
		case 113:
			releaseTransport("Gate2 health probe")
			ZagLogger.shared.info("RPPairing", "Gate2 health probe completed")
			let previous = gate2DeviceInfo ?? (name: "This iPhone", model: "", version: "", build: "")
			let appResult: (Int, Bool)
			switch gate2LastAppResult {
			case .some(let result): appResult = result
			case .none: appResult = (0, false)
			}
			publishGate2Readiness(.verified(Date()))
			gate2State = .complete(
				name: previous.name,
				model: previous.model,
				version: previous.version,
				build: previous.build,
				userAppCount: appResult.0,
				zagStoreFound: appResult.1
			)
		case -2:
			releaseTransport("Gate2 health probe")
			ZagLogger.shared.error("RPPairing", "Gate2 health probe failed: \(message)")
			gate2Failure = message
			let kind = ZagRPPairingFailure.classify(message, installationStarted: false)
			if kind != .other { publishGate2Readiness(.failed(kind, Date())) }
			gate2State = .failed(message)
		default:
			break
		}
	}

	private func recordGate2Step(code: Int32, message: String) {
		let stage: String
		var detail = message
		switch code {
		case 101:
			stage = "Start"
			let networks = ZagLocalVPNMonitor.shared.physicalNetworks
			let tunnels = ZagLocalVPNMonitor.tunnelInterfaceNames()
			detail = "endpoint \(gate2Endpoint.address):\(ZagDeviceLink.rsdPort) (\(gate2Endpoint.label)); network \(networks.isEmpty ? "none" : networks.joined(separator: ", ")); LocalDevVPN interface \(tunnels.isEmpty ? "not present" : tunnels.joined(separator: ", "))"
		case 102: stage = "TCP connection to \(gate2Endpoint.address):\(ZagDeviceLink.rsdPort)"
		case 103: stage = "Pair-Verify started"
		case 104: stage = "Pairing credentials accepted"
		case 105: stage = "TLS-PSK device tunnel"
		case 106: stage = "RSD"
		case 107:
			stage = "Device information"
			// Never record the device name.
			let fields = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
			detail = fields.dropFirst().filter { !$0.isEmpty }.joined(separator: ", ")
		case 108: stage = "Installation Proxy"
		case 109: stage = "Installed Apps Lookup"
		case 110: stage = "AFC"
		case 111: stage = "PublicStaging Write"
		case 112: stage = "PublicStaging Verify"
		case 113: stage = "Complete"
		case -2:
			let reached = gate2Steps.last?.stage ?? "Start"
			stage = "After \(reached)"
		default: return
		}
		let elapsed = Int(Date().timeIntervalSince(gate2StartedAt) * 1000)
		gate2Steps.append(ZagDiagnosticStep(stage: stage, detail: detail, elapsedMilliseconds: elapsed, failed: code == -2))
	}

	var pairingFileExists: Bool {
		FileManager.default.fileExists(atPath: Self.pairingFileURL.path)
	}

	func pairingFileForExport() throws -> URL {
		guard pairingFileExists else {
			throw PairingExportError.notPaired
		}

		let exportURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZagStore.mobiledevicepairing", isDirectory: false)

		try? FileManager.default.removeItem(at: exportURL)
		try FileManager.default.copyItem(at: Self.pairingFileURL, to: exportURL)
		return exportURL
	}

	func start() {
		guard !isRunning else { return }
		ZagLogger.shared.info("RPPairing", "Pairing session starting")
		// The PIN is generated after iOS connects while the user is normally in
		// Settings > Developer Mode. Ask for notification permission up front so
		// the code can be surfaced without forcing a blind app switch.
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
		let returnAction = UNNotificationAction(
			identifier: "zag-rppairing-return",
			title: "Return to Zag Store",
			options: [.foreground]
		)
		let category = UNNotificationCategory(
			identifier: "zag-rppairing-pin-category",
			actions: [returnAction],
			intentIdentifiers: [],
			options: []
		)
		UNUserNotificationCenter.current().setNotificationCategories([category])
		advertiser.stop()
		beginPairingBackgroundTime()
		state = .starting

		let started = "Zag Store".withCString { hostName in
			Self.pairingFileURL.path.withCString { outputPath in
				zag_rppairing_start(hostName, outputPath, zagRPPairingCallback)
			}
		}
		if !started {
			endPairingBackgroundTime()
			state = .failed("The RPPairing engine could not be started.")
			return
		}
	}

	func resetStatus() {
		guard !isRunning else { return }
		advertiser.stop()
		endPairingBackgroundTime()
		state = .idle
	}

	func forgetPairing() throws {
		guard !isRunning && !isGate2Running && !isGate4Running else {
			throw PairingResetError.busy
		}
		advertiser.stop()
		endPairingBackgroundTime()
		if FileManager.default.fileExists(atPath: Self.pairingFileURL.path) {
			try FileManager.default.removeItem(at: Self.pairingFileURL)
		}
		if FileManager.default.fileExists(atPath: Self.hostIdentityURL.path) {
			try FileManager.default.removeItem(at: Self.hostIdentityURL)
		}
		gate2DeviceInfo = nil
		gate2LastAppResult = nil
		gate2State = .idle
		gate4State = .idle
		state = .idle
	}

	fileprivate func receive(code: Int32, message: String) {
		switch code {
		case 1:
			state = .starting
		case 2:
			startNativeBonjour(from: message)
		case 3:
			state = .connected
		case 4:
			state = .pin(message)
			UIPasteboard.general.string = message
			let content = UNMutableNotificationContent()
			content.title = "Zag Store Pairing Code"
			let digits = message.filter(\.isNumber)
			if digits.count == 6 {
				let split = digits.index(digits.startIndex, offsetBy: 3)
				content.body = "\(digits[..<split]) \(digits[split...])  •  Tap to return to Zag Store"
			} else {
				content.body = "\(message)  •  Tap to return to Zag Store"
			}
			content.sound = .default
			content.categoryIdentifier = "zag-rppairing-pin-category"
			if #available(iOS 15.0, *) {
				content.interruptionLevel = .timeSensitive
			}
			UNUserNotificationCenter.current().add(
				UNNotificationRequest(
					identifier: "zag-rppairing-pin",
					content: content,
					trigger: nil
				)
			)
		case 5:
			ZagLogger.shared.info("RPPairing", "Pairing completed")
			advertiser.stop()
			endPairingBackgroundTime()
			let fields = message.split(separator: "|", omittingEmptySubsequences: false)
			let deviceName = fields.indices.contains(0) ? String(fields[0]) : "This iPhone"
			state = .paired(
				name: deviceName,
				model: fields.indices.contains(1) ? String(fields[1]) : "",
				udid: fields.indices.contains(2) ? String(fields[2]) : ""
			)

			// The PIN notification has served its purpose once iOS accepts the code.
			// Replace it with a fresh completion notification so the user still has
			// a foreground action back to Zag Store while Settings remains open.
			UNUserNotificationCenter.current().removeDeliveredNotifications(
				withIdentifiers: ["zag-rppairing-pin"]
			)
			let content = UNMutableNotificationContent()
			content.title = "Pairing Complete"
			content.body = "\(deviceName) is paired with Zag Store. Tap to return."
			content.sound = .default
			content.categoryIdentifier = "zag-rppairing-pin-category"
			if #available(iOS 15.0, *) {
				content.interruptionLevel = .timeSensitive
			}
			UNUserNotificationCenter.current().add(
				UNNotificationRequest(
					identifier: "zag-rppairing-complete",
					content: content,
					trigger: nil
				)
			)
		case -1:
			ZagLogger.shared.error("RPPairing", "Pairing failed: \(message)")
			advertiser.stop()
			endPairingBackgroundTime()
			state = .failed(message)
		default:
			break
		}
	}

	private func startNativeBonjour(from payload: String) {
		let lines = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		guard lines.count >= 2, let rustPort = UInt16(lines[0]), rustPort > 0 else {
			state = .failed("RPPairing returned invalid listener metadata.")
			return
		}
		let identifier = lines[1]
		guard !identifier.isEmpty else {
			state = .failed("RPPairing returned an empty service identifier.")
			return
		}

		var txt: [String: String] = [:]
		for line in lines.dropFirst(2) {
			guard let separator = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<separator])
			let value = String(line[line.index(after: separator)...])
			if !key.isEmpty { txt[key] = value }
		}

		do {
			try advertiser.publish(
				rustPort: rustPort,
				identifier: identifier,
				txt: txt,
				failure: { [weak self] message in
					Task { @MainActor in
						self?.state = .failed(message)
					}
				}
			)
			state = .advertising
		} catch {
			state = .failed("Native RPPairing advertisement failed: \(error.localizedDescription)")
		}
	}

	private func beginPairingBackgroundTime() {
		guard backgroundTask == .invalid else { return }
		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Zag RPPairing") { [weak self] in
			Task { @MainActor in
				guard let self else { return }
				let remaining = UIApplication.shared.backgroundTimeRemaining
				zagRPPairingLog.notice("background assertion expired; remaining=\(remaining, privacy: .public)s state=\(String(describing: self.state), privacy: .public)")
				// Expiration means iOS may suspend Zag Store; it does not mean the
				// RPPairing transaction itself has failed. In particular, once Settings
				// has connected and displayed the PIN, tearing down Bonjour here only
				// destroys a transaction that can resume when Zag Store is foregrounded.
				self.endPairingBackgroundTime()
			}
		}
		zagRPPairingLog.notice("background assertion armed; remaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)s")
	}

	func refreshPairingBackgroundTime() {
		guard isRunning else { return }
		endPairingBackgroundTime()
		beginPairingBackgroundTime()
	}

	private func endPairingBackgroundTime() {
		guard backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}

	private static var hostIdentityURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return base
			.appendingPathComponent("ZagStore", isDirectory: true)
			.appendingPathComponent("rppairing-host-identity.bin", isDirectory: false)
	}

	private static var pairingFileURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return base
			.appendingPathComponent("ZagStore", isDirectory: true)
			.appendingPathComponent("rppairing.plist", isDirectory: false)
	}
}

@MainActor
private final class ZagPairableHostAdvertiser: NSObject, @preconcurrency NetServiceDelegate {
	private var service: NetService?
	private var failure: ((String) -> Void)?

	func publish(
		rustPort: UInt16,
		identifier: String,
		txt: [String: String],
		failure: @escaping (String) -> Void
	) throws {
		stop()
		self.failure = failure

		var txtRecord: [String: Data] = [:]
		for (key, value) in txt {
			txtRecord[key] = Data(value.utf8)
		}

		let service = NetService(
			domain: "",
			type: "_remotepairing-pairable-host._tcp.",
			name: identifier,
			port: Int32(rustPort)
		)
		service.delegate = self
		if !txtRecord.isEmpty {
			service.setTXTRecord(NetService.data(fromTXTRecord: txtRecord))
		}
		self.service = service
		zagRPPairingLog.notice("publishing Rust listener directly on port \(rustPort)")
		service.publish()
	}

	func stop() {
		service?.stop()
		service?.delegate = nil
		service = nil
		failure = nil
	}

	func netServiceDidPublish(_ sender: NetService) {
		zagRPPairingLog.notice("direct Bonjour published on port \(sender.port)")
	}

	func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
		let code = errorDict[NetService.errorCode]?.intValue ?? -1
		zagRPPairingLog.error("direct Bonjour failed: \(code)")
		let callback = failure
		stop()
		callback?("RPPairing Bonjour advertisement failed (\(code)).")
	}
}


private enum PairingResetError: LocalizedError {
	case busy

	var errorDescription: String? {
		"Stop the current RPPairing operation before forgetting this iPhone."
	}
}


private enum InstalledAppsError: LocalizedError {
	case alreadyRunning
	case notPaired
	case couldNotStart
	case refreshFailed(String)

	var errorDescription: String? {
		switch self {
		case .alreadyRunning: return "An installed-app refresh is already running."
		case .notPaired: return "Pair this iPhone with Zag Store before refreshing installed apps."
		case .couldNotStart: return "The installed-app refresh could not be started."
		case .refreshFailed(let message): return message
		}
	}
}


private enum Gate4InstallError: LocalizedError {
	case alreadyRunning
	case couldNotStart
	case installFailed(String)
	/// User installs: the raw error plus what it means and whether anything
	/// changed on the device.
	case classifiedFailure(String, ZagRPPairingFailureKind)

	var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			return "Another RPPairing installation is already running."
		case .couldNotStart:
			return "The RPPairing installer could not be started."
		case .installFailed(let message):
			if message.localizedCaseInsensitiveContains("pair-verify failed") &&
				message.localizedCaseInsensitiveContains("socket io failed") {
				return message + "\n\nThe iPhone's RPPairing connection closed before installation. " +
				"Check that LocalDevVPN is connected and the device is reachable at 10.7.0.1, " +
				"then retry. If it persists, run the RPPairing health probe and verify the saved pairing file. " +
				"No installation was confirmed."
			}
			return message
		case .classifiedFailure(let message, let kind):
			return ZagRPPairingFailure.explanation(kind) + "\n\nDetails: " + message
		}
	}
}

extension Notification.Name {
	/// Ask the Local VPN monitor to check the device link now.
	static let zagDeviceLinkRecheckRequested = Notification.Name("ZagDeviceLinkRecheckRequested")
	/// Posted with a ZagRPPairingReadiness object after a real RPPairing session.
	static let zagRPPairingReadinessDidChange = Notification.Name("ZagRPPairingReadinessDidChange")
}


private enum Gate4UninstallError: LocalizedError {
	case alreadyRunning
	case invalidBundleID
	case couldNotStart
	case uninstallFailed(String)

	var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			return "Another RPPairing uninstall is already running."
		case .invalidBundleID:
			return "The app does not have a valid bundle identifier."
		case .couldNotStart:
			return "The RPPairing uninstaller could not be started."
		case .uninstallFailed(let message):
			return message
		}
	}
}


private enum PairingExportError: LocalizedError {
	case notPaired

	var errorDescription: String? {
		"Pair this iPhone before exporting its pairing file."
	}
}

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
	}

	@Published private(set) var installedBundleIDs: Set<String> = []
	@Published private(set) var installedApps: [String: InstalledAppInfo] = [:]
	@Published private(set) var installedAppsDebugKeys: String?
	@Published private(set) var installedAppsState: InstalledAppsState = .idle
	@Published private(set) var installedAppIconURLs: [String: URL] = [:]
	@Published private(set) var installedAppIconsRefreshing = false
	private var pendingInstalledApps: [String: InstalledAppInfo] = [:]
	private var installedAppsCompletion: ((Result<Set<String>, Error>) -> Void)?

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
		case progress(Int)
		case complete
		case failed(String)
	}

	@Published private(set) var gate4State: Gate4State = .idle
	private var gate4Completion: ((Result<Void, Error>) -> Void)?
	private var gate4Progress: ((Int) -> Void)?
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
		case .starting, .pairVerified, .tunnel, .rsd, .installing, .progress: return true
		default: return false
		}
	}

	func installGate4IPA(
		at sourceURL: URL,
		deviceIP: String = "10.7.0.1",
		progress: ((Int) -> Void)? = nil,
		completion: ((Result<Void, Error>) -> Void)? = nil
	) throws {
		guard !isGate4Running else {
			throw Gate4InstallError.alreadyRunning
		}
		gate4Completion = completion
		gate4Progress = progress
		let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("ZagStore/Gate4", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let localURL = directory.appendingPathComponent("gate4-test.ipa")
		try? FileManager.default.removeItem(at: localURL)

		let scoped = sourceURL.startAccessingSecurityScopedResource()
		defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
		try FileManager.default.copyItem(at: sourceURL, to: localURL)

		gate4State = .starting
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				localURL.path.withCString { ipaPath in
					zag_gate4_install(ip, pairingPath, ipaPath, zagGate4Callback)
				}
			}
		}
		if !started {
			let error = Gate4InstallError.couldNotStart
			gate4State = .failed(error.localizedDescription)
			gate4Completion?(.failure(error))
			gate4Completion = nil
		}
	}

	fileprivate func receiveGate4(code: Int32, message: String) {
		switch code {
		case 201: gate4State = .starting
		case 202: gate4State = .pairVerified
		case 203: gate4State = .tunnel
		case 204: gate4State = .rsd
		case 205: gate4State = .installing
		case 206:
			let percent = Int(message) ?? 0
			gate4State = .progress(percent)
			gate4Progress?(percent)
		case 207:
			gate4State = .complete
			gate4Completion?(.success(()))
			gate4Completion = nil
			gate4Progress = nil
		case -4:
			gate4State = .failed(message)
			let error = Gate4InstallError.installFailed(message)
			gate4Completion?(.failure(error))
			gate4Completion = nil
			gate4Progress = nil
		default: break
		}
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
			gate4UninstallRunning = false
			gate4UninstallCompletion = nil
			throw Gate4UninstallError.couldNotStart
		}
	}

	fileprivate func receiveGate4Uninstall(code: Int32, message: String) {
		switch code {
		case 307:
			gate4UninstallRunning = false
			let completion = gate4UninstallCompletion
			gate4UninstallCompletion = nil
			completion?(.success(()))
		case -5:
			gate4UninstallRunning = false
			let completion = gate4UninstallCompletion
			gate4UninstallCompletion = nil
			completion?(.failure(Gate4UninstallError.uninstallFailed(message)))
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

		pendingInstalledApps.removeAll(keepingCapacity: true)
		installedAppsCompletion = completion
		installedAppsState = .refreshing
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				zag_installed_apps(ip, pairingPath, zagInstalledAppsCallback)
			}
		}
		if !started {
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
				build: fields.indices.contains(2) ? fields[2] : ""
			)
			pendingInstalledApps[bundleID] = info
		case 404:
			installedAppsDebugKeys = message
		case 403:
			installedApps = pendingInstalledApps
			installedBundleIDs = Set(installedApps.keys)
			installedAppsState = .loaded(Int(message) ?? installedBundleIDs.count)
			let completion = installedAppsCompletion
			installedAppsCompletion = nil
			completion?(.success(installedBundleIDs))
		case -6:
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

		let directory = FileManager.default.urls(
			for: .cachesDirectory,
			in: .userDomainMask
		).first!
			.appendingPathComponent("ZagStore/InstalledAppIcons", isDirectory: true)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)

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

	func startGate2Probe(deviceIP: String = "10.7.0.1") {
		guard !isGate2Running else { return }
		gate2State = .starting
		let started = deviceIP.withCString { ip in
			Self.pairingFileURL.path.withCString { pairingPath in
				zag_gate2_probe(ip, pairingPath, zagGate2Callback)
			}
		}
		if !started {
			gate2State = .failed("The Gate 2 probe could not be started.")
		}
	}

	fileprivate func receiveGate2(code: Int32, message: String) {
		switch code {
		case 101:
			gate2State = .starting
		case 102:
			gate2State = .lockdown(message)
		case 103:
			gate2State = .pairing(message)
		case 104:
			gate2State = .pairRecord(message)
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
			let previous = gate2DeviceInfo ?? (name: "This iPhone", model: "", version: "", build: "")
			let appResult: (Int, Bool)
			switch gate2LastAppResult {
			case .some(let result): appResult = result
			case .none: appResult = (0, false)
			}
			gate2State = .complete(
				name: previous.name,
				model: previous.model,
				version: previous.version,
				build: previous.build,
				userAppCount: appResult.0,
				zagStoreFound: appResult.1
			)
		case -2:
			gate2State = .failed(message)
		default:
			break
		}
	}

	var pairingFileExists: Bool {
		FileManager.default.fileExists(atPath: Self.pairingFileURL.path)
	}

	func start() {
		guard !isRunning else { return }
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

	var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			return "Another RPPairing installation is already running."
		case .couldNotStart:
			return "The RPPairing installer could not be started."
		case .installFailed(let message):
			return message
		}
	}
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

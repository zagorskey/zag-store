import Foundation
import Network
import UIKit

/// Sends the first-launch report (see ZagFirstLaunchReport) after the
/// interface is interactive. OFF: `featureEnabled` stays false until the
/// endpoint, the privacy notice and the consent approach are approved, and
/// even then nothing is sent without the user's consent.
///
/// Never delays launch: ZagLaunchGate.finish() only starts a detached,
/// low-priority task, after the splash has gone. One report per signed IPA,
/// a bounded number of attempts (ZagFirstLaunchReport.retryDelays), retried
/// only on later launches or within this session's backoff; no background
/// tasks or wake-ups. Sends the attribution document, app and OS versions
/// and the hardware model identifier; no device name, identifier, location
/// or account data.
///
/// Consent: off until the user turns it on, in the one-time disclosure
/// (ZagFirstLaunchDisclosure) or in Settings › Privacy. Nothing is stored
/// or sent before that, and turning it off stops any pending report.
actor ZagFirstLaunchReporter {
	/// Compile-time switch. Must stay false until approval.
	static let featureEnabled = false
	/// The user's opt-in (default off).
	static let consentKey = "ZagStore.firstLaunchReportingConsent"
	/// Set once the disclosure has been answered or dismissed.
	static let disclosureShownKey = "ZagStore.firstLaunchReportingDisclosureShown"

	static let shared = ZagFirstLaunchReporter()

	private var running = false
	private let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = nil
		configuration.urlCache = nil
		configuration.httpShouldSetCookies = false
		configuration.timeoutIntervalForRequest = 15
		configuration.timeoutIntervalForResource = 30
		configuration.waitsForConnectivity = false
		return URLSession(configuration: configuration)
	}()

	/// Called by ZagLaunchGate.finish(). Returns at once.
	nonisolated static func launchBecameInteractive() {
		guard isActive else { return }
		Task.detached(priority: .background) {
			try? await Task.sleep(for: .seconds(3))
			await shared.run()
		}
	}

	nonisolated static var isActive: Bool {
		featureEnabled && UserDefaults.standard.bool(forKey: consentKey)
	}

	/// Records the user's choice; allowing starts the report at once.
	nonisolated static func setConsent(_ allowed: Bool) {
		UserDefaults.standard.set(allowed, forKey: consentKey)
		UserDefaults.standard.set(true, forKey: disclosureShownKey)
		if allowed { launchBecameInteractive() }
	}

	/// The disclosure is shown once, and only to a copy of the app that has
	/// something to report (an IPA signed on the website).
	nonisolated static var shouldPresentDisclosure: Bool {
		featureEnabled && !UserDefaults.standard.bool(forKey: disclosureShownKey) && bundledAttribution() != nil
	}

	enum Status: Equatable {
		/// This copy carries no attribution document: there is nothing to send.
		case notApplicable
		case off
		case pending
		case sent
		/// Refused by the server, or attempts or the report window ran out.
		case stopped
	}

	nonisolated static func status() -> Status {
		guard let attribution = bundledAttribution() else { return .notApplicable }
		let store = store()
		let state = store?.load()
		if state?.fingerprint == attribution.fingerprint, let outcome = state?.outcome {
			return outcome == .delivered ? .sent : .stopped
		}
		if store?.isCompleted(attribution.fingerprint) == true { return .sent }
		return UserDefaults.standard.bool(forKey: consentKey) ? .pending : .off
	}

	private func run() async {
		guard !running, Self.isActive else { return }
		running = true
		defer { running = false }
		guard let store = Self.store(), let attribution = Self.bundledAttribution() else { return }
		let metadata = await Self.metadata()
		while Self.isActive {
			let (planned, step) = ZagFirstLaunchReport.plan(
				attribution: attribution, state: store.load(),
				completed: store.isCompleted(attribution.fingerprint), now: Date())
			guard var state = planned else { return }
			switch step {
			case .none:
				try? store.save(state)
				return
			case .wait(let until):
				try? store.save(state)
				// Wait within this session only for short backoffs; longer
				// ones resume on a later launch.
				let delay = until.timeIntervalSinceNow
				guard delay <= 600 else { return }
				try? await Task.sleep(for: .seconds(max(delay, 1)))
				continue
			case .send:
				guard ZagFirstLaunchReport.isValid(metadata),
				      let url = ZagFirstLaunchReport.endpoints[attribution.environment] else {
					state.outcome = .gaveUp
					try? store.save(state)
					return
				}
				// No network: send nothing and keep the attempt for later.
				guard await Self.networkAvailable() else {
					try? store.save(ZagFirstLaunchReport.record(.unreachable, in: state, now: Date()))
					return
				}
				// Count the attempt before sending, so a crash mid-request
				// still uses up one of the bounded attempts.
				var inFlight = state
				inFlight.attempts += 1
				try? store.save(inFlight)
				let response = await send(url: url, body: ZagFirstLaunchReport.requestBody(
					attribution: attribution, metadata: metadata, firstLaunch: state.firstLaunch))
				try? store.save(ZagFirstLaunchReport.record(response, in: state, now: Date()))
			}
		}
	}

	private func send(url: URL, body: Data) async -> ZagFirstLaunchReport.Response {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = body
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		do {
			let (_, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse else { return .transportFailure }
			let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
			return .status(http.statusCode, retryAfter: retryAfter)
		} catch let error as URLError {
			return ZagFirstLaunchReport.response(for: error.code)
		} catch {
			return .transportFailure
		}
	}

	/// Whether the system currently has a usable network path (asked once,
	/// with a short timeout; no monitoring is left running).
	private static func networkAvailable() async -> Bool {
		await withCheckedContinuation { continuation in
			let monitor = NWPathMonitor()
			let queue = DispatchQueue(label: "app.zagstore.first-launch.path")
			let lock = NSLock()
			var resumed = false
			let finish: (Bool) -> Void = { value in
				lock.lock()
				defer { lock.unlock() }
				guard !resumed else { return }
				resumed = true
				monitor.cancel()
				continuation.resume(returning: value)
			}
			monitor.pathUpdateHandler = { finish($0.status == .satisfied) }
			monitor.start(queue: queue)
			// Unknown after 2 s: try anyway; a failure is classified then.
			queue.asyncAfter(deadline: .now() + 2) { finish(true) }
		}
	}

	nonisolated private static func bundledAttribution() -> ZagFirstLaunchReport.Attribution? {
		guard let url = Bundle.main.url(forResource: "ZagInstallAttribution", withExtension: "json"),
		      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
		      size <= ZagFirstLaunchReport.maxDocumentBytes,
		      let data = try? Data(contentsOf: url) else { return nil }
		return ZagFirstLaunchReport.attribution(from: data)
	}

	nonisolated private static func store() -> ZagFirstLaunchStore? {
		guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
		else { return nil }
		return ZagFirstLaunchStore(directory: support.appendingPathComponent("ZagFirstLaunch", isDirectory: true))
	}

	@MainActor
	private static func metadata() -> ZagFirstLaunchReport.Metadata {
		let info = Bundle.main.infoDictionary ?? [:]
		return ZagFirstLaunchReport.Metadata(
			appVersion: info["CFBundleShortVersionString"] as? String ?? "",
			appBuild: info["CFBundleVersion"] as? String ?? "",
			osVersion: UIDevice.current.systemVersion,
			deviceModel: hardwareModel())
	}

	/// Apple's model identifier, e.g. "iPhone17,1" (shared by every device
	/// of that model). The simulator reports its simulated model.
	private static func hardwareModel() -> String {
		if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
			return simulated
		}
		var size = 0
		guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
		var bytes = [CChar](repeating: 0, count: size)
		guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "" }
		return String(cString: bytes)
	}
}

import Foundation
import Network
import UIKit

/// Sends the first-launch report (see ZagFirstLaunchReport) after the
/// interface is interactive, for copies signed on the PREVIEW website only:
/// production documents are ignored, and copies without a document (App
/// Store-style builds, self-updates, production signings) send nothing.
///
/// Never delays launch: ZagLaunchGate.finish() only starts a detached,
/// low-priority task, after the splash has gone. One report per signed IPA,
/// a bounded number of attempts (ZagFirstLaunchReport.retryDelays), retried
/// only on later launches or within this session's backoff; no background
/// tasks or wake-ups. Sends the attribution document, app and OS versions
/// and the hardware model identifier; no device name, identifier, location
/// or account data.
///
/// No prompt (owner's decision, 2026-11-12): on by default for preview
/// copies, explained in Settings › Privacy, where turning it off stops any
/// pending report. That row appears only in copies that have a report.
///
/// Report v2 also sends the OS build, and a jailbreak classification only
/// when the user turned "Share Jailbreak Status" on (off by default): in the
/// launch report if it was on before that was first sent, otherwise once, as
/// a separate report, after the launch report was delivered.
actor ZagFirstLaunchReporter {
	/// Compile-time switch for the whole feature.
	static let featureEnabled = true
#if ZAG_FIRST_LAUNCH_TEST_BUILD
	/// Marks the binary; zag-check-bundle-contents.sh, and so
	/// publish-zag-release.zsh, refuse any bundle that contains it.
	static let testBuildMarker: String? = "ZAG-FIRST-LAUNCH-TEST-BUILD-NOT-FOR-RELEASE"
#else
	static let testBuildMarker: String? = nil
#endif
	/// Set when the user turns the report off in Settings › Privacy.
	static let optOutKey = "ZagStore.firstLaunchReportingOptOut"
	/// Set only when the user turns jailbreak sharing on (off by default).
	static let jailbreakOptInKey = "ZagStore.jailbreakReportingOptIn"

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
		featureEnabled && !UserDefaults.standard.bool(forKey: optOutKey)
	}

	/// Records the user's choice; turning it back on resumes a pending report.
	nonisolated static func setSharing(_ enabled: Bool) {
		UserDefaults.standard.set(!enabled, forKey: optOutKey)
		if enabled { launchBecameInteractive() }
	}

	/// Whether the user turned jailbreak sharing on (and reporting is on).
	nonisolated static var sharesJailbreak: Bool {
		isActive && UserDefaults.standard.bool(forKey: jailbreakOptInKey)
	}

	/// Records the jailbreak choice; turning it on sends the separate
	/// jailbreak report if the launch report has already been delivered.
	nonisolated static func setJailbreakSharing(_ enabled: Bool) {
		UserDefaults.standard.set(enabled, forKey: jailbreakOptInKey)
		if enabled { launchBecameInteractive() }
	}

	/// Whether this copy carries a preview attribution document (an IPA
	/// signed on the preview website), so has a report to send.
	nonisolated static var hasReport: Bool {
		featureEnabled && bundledAttribution() != nil
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
		let store = store(.launch)
		let state = store?.load()
		if state?.fingerprint == attribution.fingerprint, let outcome = state?.outcome {
			return outcome == .delivered ? .sent : .stopped
		}
		if store?.isCompleted(attribution.fingerprint) == true { return .sent }
		return UserDefaults.standard.bool(forKey: optOutKey) ? .off : .pending
	}

	private func run() async {
		guard !running, Self.isActive else { return }
		running = true
		defer { running = false }
		guard let store = Self.store(.launch), let attribution = Self.bundledAttribution() else { return }
		let metadata = await Self.metadata()
		let osBuild = Self.osBuild()
		await deliver(store: store, attribution: attribution, metadata: metadata, osBuild: osBuild)
		await deliverJailbreak(launch: store, attribution: attribution, metadata: metadata)
	}

	/// The jailbreak report, once, when sharing is on and the launch report
	/// was delivered as v2 without the classification. Nothing otherwise.
	private func deliverJailbreak(launch: ZagFirstLaunchStore, attribution: ZagFirstLaunchReport.Attribution,
	                              metadata: ZagFirstLaunchReport.Metadata) async {
		guard Self.sharesJailbreak, let store = Self.store(.jailbreak),
		      let state = launch.load(), state.fingerprint == attribution.fingerprint,
		      state.outcome == .delivered, state.version == 2, state.jailbreak != true
		else { return }
		await deliver(store: store, attribution: attribution, metadata: metadata, osBuild: nil,
		              kind: .jailbreak, start: state.firstLaunch)
	}

	/// Sends one report kind until it is delivered, refused, out of attempts,
	/// or waiting for a later launch.
	private func deliver(store: ZagFirstLaunchStore, attribution: ZagFirstLaunchReport.Attribution,
	                     metadata: ZagFirstLaunchReport.Metadata, osBuild: String?,
	                     kind: ZagFirstLaunchReport.Kind = .launch, start: Date? = nil) async {
		while Self.isActive, kind == .launch || Self.sharesJailbreak {
			let (planned, step) = ZagFirstLaunchReport.plan(
				attribution: attribution, state: store.load(),
				completed: store.isCompleted(attribution.fingerprint), now: Date(),
				kind: kind, start: start, includeJailbreak: Self.sharesJailbreak)
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
				// Detected only for a report that carries it, and never kept.
				let carriesJailbreak = kind == .jailbreak || (state.version == 2 && state.jailbreak == true)
				let jailbreak = carriesJailbreak ? Self.detectJailbreak() : nil
				let body = ZagFirstLaunchReport.requestBody(
					for: state, attribution: attribution, metadata: metadata, osBuild: osBuild, jailbreak: jailbreak)
				guard kind == .jailbreak || ZagFirstLaunchReport.isValid(metadata), !body.isEmpty,
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
				let response = await send(url: url, body: body)
				let recorded = ZagFirstLaunchReport.record(response, in: state, now: Date())
				try? store.save(recorded)
				// A launch report that carried the classification is the
				// jailbreak report too: never send that separately.
				if kind == .launch, recorded.outcome == .delivered, recorded.jailbreak == true {
					Self.store(.jailbreak)?.markCompleted(attribution.fingerprint)
				}
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
			let (data, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse else { return .transportFailure }
			let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
			return ZagFirstLaunchReport.response(status: http.statusCode, body: data, retryAfter: retryAfter)
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

	nonisolated private static func store(_ kind: ZagFirstLaunchReport.Kind = .launch) -> ZagFirstLaunchStore? {
		guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
		else { return nil }
		return ZagFirstLaunchStore(directory: support.appendingPathComponent("ZagFirstLaunch", isDirectory: true),
		                           kind: kind)
	}

	/// Apple's OS build number, e.g. "23B85" (shared by every device on that
	/// release).
	private static func osBuild() -> String? {
		var size = 0
		guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
		var bytes = [CChar](repeating: 0, count: size)
		guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return nil }
		return String(cString: bytes)
	}

	/// Detector version ZagFirstLaunchReport.detectorVersion: whether
	/// well-known locations of rootless (/var/jb) and rootful jailbreaks
	/// exist. Read-only, and only the classification is returned: which
	/// location matched is never kept, logged or sent. No installed-app
	/// queries. The simulator is "unknown" (its file system is the Mac's).
	nonisolated static func detectJailbreak() -> ZagFirstLaunchReport.Jailbreak {
#if targetEnvironment(simulator)
		return ZagFirstLaunchReport.classify(rootless: false, rootful: false, inspected: false)
#else
		let files = FileManager.default
		let rootless = (try? files.destinationOfSymbolicLink(atPath: "/var/jb")) != nil
			|| files.fileExists(atPath: "/var/jb")
		let rootful = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
		               "/bin/bash", "/usr/sbin/sshd", "/etc/apt", "/usr/lib/libsubstrate.dylib"]
			.contains { files.fileExists(atPath: $0) }
		return ZagFirstLaunchReport.classify(rootless: rootless, rootful: rootful, inspected: true)
#endif
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

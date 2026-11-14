import Foundation
import UIKit

/// Sends the anonymous usage activity (see ZagActivityReport) while Zag Store
/// is in the foreground: a session start, a heartbeat about once a minute and
/// a best-effort end on the way to the background.
///
/// Never delays launch or anything else: it starts from ZagLaunchGate.finish(),
/// after the interface is interactive, and each event is one short request
/// off the main thread. Fire and forget: a failed event is not retried or
/// stored (the next heartbeat stands in for it), at most two requests are in
/// flight, and nothing is kept on disk except the opt-out. No background
/// tasks or wake-ups: in the background nothing runs.
///
/// On by default (owner's decision, 2026-11-14). Turning it off in Settings ›
/// Privacy stops the heartbeat, cancels requests in flight and forgets the
/// session at once; the opt-out is checked again before every event.
/// Independent of ZagFirstLaunchReporter and its setting.
@MainActor
final class ZagActivityReporter {
	/// Compile-time switch for the whole feature.
	nonisolated static let featureEnabled = true
	/// Set when the user turns usage statistics off in Settings › Privacy.
	nonisolated static let optOutKey = "ZagStore.usageAnalyticsOptOut"

	static let shared = ZagActivityReporter()

	nonisolated static var isActive: Bool {
		featureEnabled && !UserDefaults.standard.bool(forKey: optOutKey)
	}

	private static let maxInFlight = 2
	private nonisolated static let urlSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = nil
		configuration.urlCache = nil
		configuration.httpShouldSetCookies = false
		configuration.timeoutIntervalForRequest = 10
		configuration.timeoutIntervalForResource = 15
		configuration.waitsForConnectivity = false
		configuration.httpMaximumConnectionsPerHost = 1
		return URLSession(configuration: configuration)
	}()

	private var started = false
	private var observers: [NSObjectProtocol] = []
	private var session = ZagActivityReport.Session()
	private var heartbeatTask: Task<Void, Never>?
	/// Refused or switched off by the server: nothing more until the next launch.
	private var stoppedForLaunch = false
	private var pausedUntil: Date?
	private var inFlight = 0
	/// Raised by the opt-out, so a response that arrives later changes nothing.
	private var generation = 0
	private lazy var endpoint: URL? = Self.endpointURL()
	private lazy var metadata: ZagActivityReport.Metadata = Self.readMetadata()

	private init() {}

	/// Called by ZagLaunchGate.finish(). Returns at once.
	static func launchBecameInteractive() {
		guard featureEnabled else { return }
		shared.start()
	}

	/// Records the user's choice and applies it at once.
	static func setSharing(_ enabled: Bool) {
		UserDefaults.standard.set(!enabled, forKey: optOutKey)
		if enabled { shared.resume() } else { shared.shutDown() }
	}

	private func start() {
		guard !started else { return }
		started = true
		let center = NotificationCenter.default
		observers = [
			center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
				MainActor.assumeIsolated { ZagActivityReporter.shared.becameActive() }
			},
			center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
				MainActor.assumeIsolated { ZagActivityReporter.shared.enteredBackground() }
			},
		]
		if UIApplication.shared.applicationState == .active { becameActive() }
	}

	private func resume() {
		guard started, UIApplication.shared.applicationState == .active else { return }
		becameActive()
	}

	private func shutDown() {
		generation += 1
		stopHeartbeat()
		session.reset()
		Self.urlSession.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
	}

	private var canSend: Bool {
		Self.isActive && !stoppedForLaunch
	}

	private func becameActive() {
		guard canSend, let step = session.becameActive(now: Date()) else { return }
		send(step)
		scheduleHeartbeats()
	}

	private func enteredBackground() {
		stopHeartbeat()
		guard canSend, let step = session.enteredBackground(now: Date()) else { return }
		send(step)
	}

	private func scheduleHeartbeats() {
		heartbeatTask?.cancel()
		heartbeatTask = Task { [weak self] in
			while !Task.isCancelled {
				let delay = ZagActivityReport.heartbeatInterval + .random(in: 0...ZagActivityReport.heartbeatJitter)
				try? await Task.sleep(for: .seconds(delay))
				guard !Task.isCancelled, let self, self.canSend, let step = self.session.heartbeat() else { return }
				self.send(step)
			}
		}
	}

	private func stopHeartbeat() {
		heartbeatTask?.cancel()
		heartbeatTask = nil
	}

	private func send(_ step: ZagActivityReport.Session.Step) {
		guard canSend, let url = endpoint, inFlight < Self.maxInFlight else { return }
		if let pausedUntil, pausedUntil > Date() { return }
		let body = ZagActivityReport.requestBody(step, metadata: metadata)
		// Metadata the server would refuse: never send anything this launch.
		guard !body.isEmpty else { return stop() }
		inFlight += 1
		let generation = self.generation
		Task.detached(priority: .utility) {
			let outcome = await Self.post(body, to: url)
			await MainActor.run { ZagActivityReporter.shared.finished(outcome, generation: generation) }
		}
	}

	private func finished(_ outcome: ZagActivityReport.Outcome, generation: Int) {
		inFlight = max(inFlight - 1, 0)
		guard generation == self.generation else { return }
		switch outcome {
		case .carryOn: break
		case .pause(let seconds): pausedUntil = Date().addingTimeInterval(seconds)
		case .stop: stop()
		}
	}

	private func stop() {
		stoppedForLaunch = true
		stopHeartbeat()
		session.reset()
	}

	private nonisolated static func post(_ body: Data, to url: URL) async -> ZagActivityReport.Outcome {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = body
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		guard let (_, response) = try? await urlSession.data(for: request),
		      let http = response as? HTTPURLResponse else { return .carryOn }
		let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
		return ZagActivityReport.outcome(status: http.statusCode, retryAfter: retryAfter)
	}

	/// The site this copy was signed on, as the first-launch report chooses
	/// it; otherwise production (preview only in the test-only build).
	private static func endpointURL() -> URL? {
		var environment: String?
		if let url = Bundle.main.url(forResource: "ZagInstallAttribution", withExtension: "json"),
		   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
		   size <= ZagFirstLaunchReport.maxDocumentBytes,
		   let data = try? Data(contentsOf: url) {
			environment = ZagFirstLaunchReport.attribution(from: data)?.environment
		}
		let chosen = ZagActivityReport.environment(
			attribution: environment, testBuild: ZagFirstLaunchReporter.testBuildMarker != nil)
		return ZagActivityReport.endpoints[chosen]
	}

	private static func readMetadata() -> ZagActivityReport.Metadata {
		let info = Bundle.main.infoDictionary ?? [:]
		return ZagActivityReport.Metadata(
			appVersion: info["CFBundleShortVersionString"] as? String ?? "",
			appBuild: info["CFBundleVersion"] as? String ?? "",
			osVersion: UIDevice.current.systemVersion)
	}
}

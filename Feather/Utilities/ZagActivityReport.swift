import Foundation
import Security

/// Anonymous usage activity: the pure parts, with no UIKit, so they compile
/// into scripts/ZagActivityReportTests.swift. ZagActivityReporter runs them.
///
/// While Zag Store is in the foreground it sends a session start, a heartbeat
/// about once a minute, and a best-effort end when it goes to the background,
/// so the website can show how many sessions are active. Each event carries a
/// random session id (new for every session, never stored, never linked to
/// an earlier session or day), a sequence number, the Zag Store version and
/// build and the iOS version. Nothing else: no device, account, location,
/// installed-app or signing data.
///
/// On by default (owner's decision, 2026-11-14), with an opt-out in
/// Settings › Privacy that is checked before every event. Independent of the
/// first-launch report.
enum ZagActivityReport {
	static let schemaVersion = 1

	/// One per website, as ZagFirstLaunchReport.endpoints.
	static let endpoints: [String: URL] = [
		"preview": URL(string: "https://preview.zagstore.app/api/zag/v1/activity")!,
		"production": URL(string: "https://zagstore.app/api/zag/v1/activity")!,
	]

	/// Heartbeat period while in the foreground, plus up to `heartbeatJitter`
	/// so copies opened together do not report in step.
	static let heartbeatInterval: TimeInterval = 60
	static let heartbeatJitter: TimeInterval = 5
	/// A session continues after a shorter time in the background; after at
	/// least this long the next foreground starts a new one.
	static let sessionRenewal: TimeInterval = 300
	/// Longest pause the server can ask for (Retry-After) within a launch.
	static let maxPause: TimeInterval = 600
	static let defaultPause: TimeInterval = 60
	/// Every body is far smaller; the server refuses anything over 512 bytes.
	static let maxBodyBytes = 512

	enum Event: String {
		case start, heartbeat, end
	}

	/// The site a copy reports to: the one it was signed on (its attribution
	/// document's environment); otherwise production, or preview for the
	/// test-only acceptance build. Released copies never choose preview
	/// without a preview attribution document.
	static func environment(attribution: String?, testBuild: Bool) -> String {
		if let attribution, endpoints[attribution] != nil { return attribution }
		return testBuild ? "preview" : "production"
	}

	// MARK: Metadata

	struct Metadata: Equatable {
		let appVersion: String
		let appBuild: String
		let osVersion: String
	}

	/// The same patterns the server enforces (as the first-launch report).
	static func isValid(_ metadata: Metadata) -> Bool {
		matches(metadata.appVersion, #"^\d{1,4}(\.\d{1,4}){0,3}$"#)
			&& matches(metadata.appBuild, #"^\d{1,6}(\.\d{1,6}){0,2}$"#)
			&& matches(metadata.osVersion, #"^\d{1,3}(\.\d{1,3}){0,2}$"#)
	}

	private static func matches(_ value: String, _ pattern: String) -> Bool {
		value.range(of: pattern, options: .regularExpression) != nil
	}

	// MARK: Session id

	/// 128 random bits as 22 base64url characters.
	static func newSessionID() -> String {
		var bytes = [UInt8](repeating: 0, count: 16)
		if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
			var generator = SystemRandomNumberGenerator()
			bytes = bytes.map { _ in generator.next() }
		}
		return Data(bytes).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	static func isSessionID(_ value: String) -> Bool {
		value.range(of: #"^[A-Za-z0-9_-]{21}[AQgw]$"#, options: .regularExpression) != nil
	}

	// MARK: Session lifecycle

	/// What the reporter sends, decided from foreground and background
	/// transitions only. Times are the device clock and stay on the device:
	/// the server uses its own receive time.
	struct Session: Equatable {
		private(set) var id: String?
		private(set) var sequence = 0
		private(set) var backgroundedAt: Date?

		struct Step: Equatable {
			let event: Event
			let session: String
			let sequence: Int
		}

		/// Foreground: a new session (start) the first time and after at
		/// least `sessionRenewal` in the background, otherwise the same
		/// session continues with an immediate heartbeat. Nil when already in
		/// the foreground (for example after Control Center was closed).
		mutating func becameActive(now: Date, newID: () -> String = ZagActivityReport.newSessionID) -> Step? {
			if id != nil, backgroundedAt == nil { return nil }
			defer { backgroundedAt = nil }
			if let id, let backgroundedAt, now.timeIntervalSince(backgroundedAt) < ZagActivityReport.sessionRenewal,
			   now >= backgroundedAt {
				return next(.heartbeat, id)
			}
			let id = newID()
			self.id = id
			sequence = 0
			return next(.start, id)
		}

		/// A heartbeat while in the foreground, or nil without a session.
		mutating func heartbeat() -> Step? {
			guard let id, backgroundedAt == nil else { return nil }
			return next(.heartbeat, id)
		}

		/// Background: the end event, once, or nil without a session.
		mutating func enteredBackground(now: Date) -> Step? {
			guard let id, backgroundedAt == nil else { return nil }
			backgroundedAt = now
			return next(.end, id)
		}

		/// Opt-out or a server stop: forget the session; nothing is sent.
		mutating func reset() {
			self = Session()
		}

		private mutating func next(_ event: Event, _ id: String) -> Step {
			let step = Step(event: event, session: id, sequence: sequence)
			sequence += 1
			return step
		}
	}

	// MARK: Request

	/// The event as the server's strict schema expects it, or empty when the
	/// metadata does not match it (nothing is sent then).
	static func requestBody(_ step: Session.Step, metadata: Metadata) -> Data {
		guard isValid(metadata), isSessionID(step.session), (0...100_000).contains(step.sequence) else { return Data() }
		let body: [String: Any] = [
			"v": schemaVersion,
			"event": step.event.rawValue,
			"session": step.session,
			"seq": step.sequence,
			"app_version": metadata.appVersion,
			"app_build": metadata.appBuild,
			"os_version": metadata.osVersion,
		]
		guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
		      data.count <= maxBodyBytes else { return Data() }
		return data
	}

	// MARK: Response

	enum Outcome: Equatable {
		/// Delivered (202), or a failure worth no action: the next heartbeat
		/// is the retry, and nothing is queued.
		case carryOn
		/// 429 or 503: send nothing until then.
		case pause(TimeInterval)
		/// Refused (400, 404, 405, 413, 415) or switched off on the server
		/// (410): send nothing more until the next launch.
		case stop
	}

	static func outcome(status: Int, retryAfter: TimeInterval?) -> Outcome {
		switch status {
		case 200...299: return .carryOn
		case 400, 404, 405, 410, 411, 413, 415: return .stop
		case 429, 503: return .pause(min(max(retryAfter ?? defaultPause, 1), maxPause))
		default: return .carryOn
		}
	}
}

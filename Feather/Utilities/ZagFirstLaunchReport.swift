import CryptoKit
import Foundation
import Security

/// First-launch report: the pure parts, with no UIKit, so they compile into
/// scripts/ZagFirstLaunchReportTests.swift. ZagFirstLaunchReporter runs them.
///
/// A website-signed IPA carries ZagInstallAttribution.json, sealed by the
/// signature, holding a random token for that one signing job. On the first
/// launch of that IPA the app sends the document back once, with four
/// metadata fields, so the server can count the job as launched. Nothing is
/// sent on later launches, for apps without the file (App Store-style builds,
/// self-updates), or when the user turned it off.
///
/// The token only shows that the sender holds a copy of that job's IPA. It
/// does not identify a device, and the server counts at most one launch per
/// job however many copies report.
///
/// Report v2 (the website's REPORT-V2.md) adds a random report id, the same
/// for every retry of one report (the server's idempotency key), the OS build,
/// and, only when the user turned it on, a jailbreak classification. A server
/// that answers unsupported_version gets the v1 report instead.
enum ZagFirstLaunchReport {
	static let documentName = "ZagInstallAttribution.json"
	static let maxDocumentBytes = 256
	static let tokenLifetime: TimeInterval = 30 * 24 * 3600
	/// Nothing is sent later than this after the first launch: the server's
	/// token validity is 30 days from the signing, which came first.
	static let reportWindow: TimeInterval = tokenLifetime - 24 * 3600
	/// Delay before attempt n + 1 (seconds); the length bounds the attempts.
	/// Ten requests at most, spread over about 14 days, so a report survives
	/// days of server trouble without ever being chatty.
	static let retryDelays: [TimeInterval] = [60, 300, 1800, 7200, 21_600, 86_400, 172_800, 345_600, 604_800]
	static var maxAttempts: Int { retryDelays.count + 1 }
	/// With no network at all nothing is sent and no attempt is used; the
	/// next try is on a launch at least this much later. A device offline for
	/// longer than the schedule therefore still reports when it reconnects,
	/// within the report window.
	static let offlineRecheck: TimeInterval = 900

	/// One per website. The signed document's environment chooses it, so a
	/// report only ever goes back to the site the copy was signed on; any
	/// other environment has no endpoint and is not parsed as an attribution.
	static let endpoints: [String: URL] = [
		"preview": URL(string: "https://preview.zagstore.app/api/zag/v1/first-launch")!,
		"production": URL(string: "https://zagstore.app/api/zag/v1/first-launch")!,
	]

	/// The version a new report is sent as.
	static let reportVersion = 2
	/// The jailbreak detector's version ("checks"): the server never mixes
	/// results from different detector versions.
	static let detectorVersion = 1

	// MARK: Attribution document

	struct Attribution: Equatable {
		let environment: String
		let token: String
		/// SHA-256 of the document, kept locally to recognise the same IPA.
		let fingerprint: String
	}

	/// The document exactly as the signing worker writes it, or nil.
	static func attribution(from data: Data) -> Attribution? {
		guard (1...maxDocumentBytes).contains(data.count),
		      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      Set(object.keys) == ["v", "env", "tok"],
		      // An integer 1: JSON true and 1.0 are refused (CFBoolean has its own type).
		      let version = object["v"] as? NSNumber, CFGetTypeID(version) == CFNumberGetTypeID(),
		      !CFNumberIsFloatType(version), version.intValue == 1,
		      let environment = object["env"] as? String, endpoints[environment] != nil,
		      let token = object["tok"] as? String, isToken(token)
		else { return nil }
		return Attribution(environment: environment, token: token, fingerprint: sha256(data))
	}

	/// 43 base64url characters encoding exactly 32 bytes.
	static func isToken(_ token: String) -> Bool {
		guard token.utf8.count == 43,
		      token.utf8.allSatisfy({ isBase64URL($0) }) else { return false }
		// The last character carries only 4 bits; the 2 spare bits must be zero.
		let last = token.utf8.last!
		let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
		guard let index = alphabet.firstIndex(of: last) else { return false }
		return index & 0b11 == 0
	}

	private static func isBase64URL(_ c: UInt8) -> Bool {
		(c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45 || c == 95
	}

	// MARK: Metadata

	struct Metadata: Equatable {
		let appVersion: String
		let appBuild: String
		let osVersion: String
		let deviceModel: String
	}

	/// The same patterns the server enforces; anything else is not sent.
	static func isValid(_ metadata: Metadata) -> Bool {
		matches(metadata.appVersion, #"^\d{1,4}(\.\d{1,4}){0,3}$"#)
			&& matches(metadata.appBuild, #"^\d{1,6}(\.\d{1,6}){0,2}$"#)
			&& matches(metadata.osVersion, #"^\d{1,3}(\.\d{1,3}){0,2}$"#)
			&& matches(metadata.deviceModel, #"^(iPhone|iPad|iPod)\d{1,3},\d{1,3}$"#)
	}

	private static func matches(_ value: String, _ pattern: String) -> Bool {
		value.range(of: pattern, options: .regularExpression) != nil
	}

	/// Apple's build number, as the server accepts it (23B85; betas 22G5054d).
	static func isOSBuild(_ value: String) -> Bool {
		matches(value, #"^\d{1,2}[A-Z]\d{1,5}[a-z]?$"#)
	}

	/// 128 random bits as 22 base64url characters: the report id.
	static func newReportID() -> String {
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

	// MARK: Jailbreak classification (sent only when the user turned it on)

	struct Jailbreak: Equatable {
		enum Status: String { case detected, notDetected = "not_detected", unknown }
		enum Layout: String { case rootless, rootful }
		let status: Status
		let layout: Layout?
	}

	/// The classification from what the detector found on the device. Which
	/// location matched is never part of it.
	static func classify(rootless: Bool, rootful: Bool, inspected: Bool) -> Jailbreak {
		guard inspected else { return Jailbreak(status: .unknown, layout: nil) }
		switch (rootless, rootful) {
		case (true, false): return Jailbreak(status: .detected, layout: .rootless)
		case (false, true): return Jailbreak(status: .detected, layout: .rootful)
		case (true, true): return Jailbreak(status: .detected, layout: nil)
		case (false, false): return Jailbreak(status: .notDetected, layout: nil)
		}
	}

	/// The server's strict form: consent, status, optional layout, detector version.
	static func jailbreakObject(_ jailbreak: Jailbreak) -> [String: Any] {
		var object: [String: Any] = ["consent": "opt_in", "status": jailbreak.status.rawValue, "checks": detectorVersion]
		if jailbreak.status == .detected, let layout = jailbreak.layout { object["layout"] = layout.rawValue }
		return object
	}

	// MARK: Request

	enum Kind: String, Codable {
		/// The first-launch report.
		case launch
		/// The separate jailbreak report, sent once when the user turns
		/// jailbreak sharing on after the launch report was delivered.
		case jailbreak
	}

	/// The v1 report, exactly what every earlier build sends.
	static func requestBody(attribution: Attribution, metadata: Metadata, firstLaunch: Date) -> Data {
		encode(launchFields(attribution: attribution, metadata: metadata, firstLaunch: firstLaunch, version: 1))
	}

	/// The body for `state`: v1, or v2 with the state's report id. The
	/// jailbreak classification goes into a v2 launch report only when the
	/// state was created with jailbreak sharing on (`state.jailbreak`), and is
	/// the whole content of a jailbreak report.
	static func requestBody(for state: State, attribution: Attribution, metadata: Metadata,
	                        osBuild: String?, jailbreak: Jailbreak?) -> Data {
		let version = state.version ?? 1
		if (state.kind ?? .launch) == .jailbreak {
			guard version == 2, let reportID = state.reportID, let jailbreak else { return Data() }
			return encode(["v": 2, "kind": "jailbreak", "report_id": reportID,
			               "attribution": document(attribution), "jailbreak": jailbreakObject(jailbreak)])
		}
		guard version == 2, let reportID = state.reportID else {
			return requestBody(attribution: attribution, metadata: metadata, firstLaunch: state.firstLaunch)
		}
		var body = launchFields(attribution: attribution, metadata: metadata, firstLaunch: state.firstLaunch, version: 2)
		body["kind"] = "launch"
		body["report_id"] = reportID
		if let osBuild, isOSBuild(osBuild) { body["os_build"] = osBuild }
		if state.jailbreak == true, let jailbreak { body["jailbreak"] = jailbreakObject(jailbreak) }
		return encode(body)
	}

	private static func document(_ attribution: Attribution) -> [String: Any] {
		["v": 1, "env": attribution.environment, "tok": attribution.token]
	}

	private static func launchFields(attribution: Attribution, metadata: Metadata, firstLaunch: Date,
	                                 version: Int) -> [String: Any] {
		[
			"v": version,
			"attribution": document(attribution),
			"app_version": metadata.appVersion,
			"app_build": metadata.appBuild,
			"os_version": metadata.osVersion,
			"device_model": metadata.deviceModel,
			"launched_at": utcString(firstLaunch),
		]
	}

	private static func encode(_ body: [String: Any]) -> Data {
		(try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
	}

	static func utcString(_ date: Date) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "UTC")
		formatter.calendar = Calendar(identifier: .gregorian)
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return formatter.string(from: date)
	}

	// MARK: State

	enum Outcome: String, Codable {
		/// The server answered 202 (it never says whether the token matched).
		case delivered
		/// The server refused the request as malformed; retrying cannot help.
		case rejected
		/// Attempts or the token lifetime ran out.
		case gaveUp
	}

	struct State: Codable, Equatable {
		var fingerprint: String
		var firstLaunch: Date
		var attempts: Int
		var nextAttempt: Date?
		var outcome: Outcome?
		/// The version being sent. nil: a report started by an earlier build,
		/// which sent v1, so it stays v1.
		var version: Int?
		/// The v2 idempotency key, the same for every retry of this report.
		var reportID: String?
		/// nil: the launch report.
		var kind: Kind?
		/// Launch report: whether it carries the jailbreak classification.
		/// Fixed when the report is created, so a retry never changes what
		/// the same report id stands for.
		var jailbreak: Bool?
	}

	enum Step: Equatable {
		case none
		case wait(until: Date)
		case send
	}

	/// What to do on an interactive launch. `state` may be nil after local
	/// data loss; `completed` is the Keychain record of finished documents.
	/// A new report gets `reportVersion`, a new report id, and `start` as its
	/// first launch (the jailbreak report keeps the launch report's, so it
	/// stays within the token's lifetime).
	static func plan(attribution: Attribution?, state: State?, completed: Bool, now: Date,
	                 kind: Kind = .launch, start: Date? = nil, includeJailbreak: Bool = false,
	                 newID: () -> String = newReportID) -> (State?, Step) {
		guard let attribution else { return (state, .none) }
		guard !completed else { return (state, .none) }
		var current = state
		if current?.fingerprint != attribution.fingerprint {
			// First launch of this IPA (a different job's IPA starts afresh).
			current = State(fingerprint: attribution.fingerprint, firstLaunch: start ?? now, attempts: 0,
			                version: reportVersion, reportID: newID(), kind: kind == .launch ? nil : kind,
			                jailbreak: kind == .launch ? includeJailbreak : nil)
		}
		guard var state = current else { return (nil, .none) }
		if state.outcome != nil { return (state, .none) }
		if state.attempts >= maxAttempts || now.timeIntervalSince(state.firstLaunch) > reportWindow {
			state.outcome = .gaveUp
			return (state, .none)
		}
		if let next = state.nextAttempt, now < next { return (state, .wait(until: next)) }
		return (state, .send)
	}

	enum Response: Equatable {
		case status(Int, retryAfter: TimeInterval?)
		/// 400 {"status": "unsupported_version"}: the server does not know
		/// this report version. The only answer that changes the version.
		case unsupportedVersion
		/// The request may have reached the network (DNS, TLS, timeout...).
		case transportFailure
		/// The device had no usable network: nothing left it.
		case unreachable
	}

	/// How a URLSession failure counts: only failures that prove the device
	/// had no network leave the attempt budget untouched.
	static func response(for code: URLError.Code) -> Response {
		switch code {
		case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
			return .unreachable
		default:
			return .transportFailure
		}
	}

	/// How an HTTP answer counts; the body matters only for a 400.
	static func response(status: Int, body: Data, retryAfter: TimeInterval?) -> Response {
		if status == 400, body.count <= 1024,
		   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
		   object["status"] as? String == "unsupported_version" {
			return .unsupportedVersion
		}
		return .status(status, retryAfter: retryAfter)
	}

	/// The state after one attempt.
	static func record(_ response: Response, in state: State, now: Date) -> State {
		var state = state
		if response == .unreachable {
			state.nextAttempt = now.addingTimeInterval(offlineRecheck)
			return state
		}
		state.attempts += 1
		switch response {
		case .unsupportedVersion where (state.version ?? 1) > 1 && (state.kind ?? .launch) == .launch:
			// Nothing was looked up or stored: send the v1 report right away
			// (v1 carries no jailbreak classification).
			state.version = 1
			state.reportID = nil
			state.jailbreak = false
			state.nextAttempt = nil
		case .unsupportedVersion:
			// v1 itself, or a jailbreak report, which has no older form.
			state.outcome = .rejected
			state.nextAttempt = nil
		case .status(202, _):
			state.outcome = .delivered
			state.nextAttempt = nil
		case .status(let code, _) where [400, 404, 405, 411, 413, 415].contains(code):
			state.outcome = .rejected
			state.nextAttempt = nil
		case .status(_, let retryAfter):
			state.nextAttempt = now.addingTimeInterval(delay(after: state.attempts, retryAfter: retryAfter))
		case .transportFailure, .unreachable:
			state.nextAttempt = now.addingTimeInterval(delay(after: state.attempts, retryAfter: nil))
		}
		if state.outcome == nil, state.attempts >= maxAttempts { state.outcome = .gaveUp }
		return state
	}

	static func delay(after attempts: Int, retryAfter: TimeInterval?) -> TimeInterval {
		let scheduled = retryDelays[min(max(attempts - 1, 0), retryDelays.count - 1)]
		guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return scheduled }
		return max(scheduled, min(retryAfter, 86_400))
	}

	static func sha256(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

/// The durable local state: a JSON file in Application Support (excluded
/// from backups) plus a Keychain record of finished documents, which
/// outlives the app's files. Neither leaves the device.
struct ZagFirstLaunchStore {
	let directory: URL
	let keychainService: String
	/// The launch report and the jailbreak report each keep their own file
	/// and their own Keychain records.
	let kind: ZagFirstLaunchReport.Kind

	init(directory: URL, keychainService: String = "app.zagstore.ios.first-launch-report",
	     kind: ZagFirstLaunchReport.Kind = .launch) {
		self.directory = directory
		self.keychainService = keychainService
		self.kind = kind
	}

	private var fileURL: URL {
		directory.appendingPathComponent(kind == .launch ? "state.json" : "jailbreak-state.json")
	}

	/// The launch report's records keep their original names.
	private func account(_ fingerprint: String) -> String {
		kind == .launch ? fingerprint : "jailbreak:" + fingerprint
	}

	func load() -> ZagFirstLaunchReport.State? {
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		return try? JSONDecoder().decode(ZagFirstLaunchReport.State.self, from: data)
	}

	func save(_ state: ZagFirstLaunchReport.State) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var folder = directory
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try? folder.setResourceValues(values)
		try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic])
		if state.outcome != nil { markCompleted(state.fingerprint) }
	}

	func isCompleted(_ fingerprint: String) -> Bool {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: keychainService,
			kSecAttrAccount as String: account(fingerprint),
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
	}

	func markCompleted(_ fingerprint: String) {
		let item: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: keychainService,
			kSecAttrAccount as String: account(fingerprint),
			kSecValueData as String: Data("1".utf8),
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		]
		// Best effort: the file state and the server's one-launch-per-job
		// rule still hold if the Keychain refuses (errSecDuplicateItem is fine).
		_ = SecItemAdd(item as CFDictionary, nil)
	}
}

import Foundation
import Security

// Compiled with Feather/Utilities/ZagFirstLaunchReport.swift by
// scripts/test-zag-first-launch-report.sh. Uses a temporary directory and a
// disposable Keychain service; no app state is read or changed.

@main struct ZagFirstLaunchReportTests {
	static func main() {
		var failures = 0
		func expect(_ condition: Bool, _ label: String) {
			print((condition ? "PASS  " : "FAIL  ") + label)
			if !condition { failures += 1 }
		}
		typealias R = ZagFirstLaunchReport

		// A document exactly as zag_install_attribution.issue() writes it
		// (compact JSON, sorted keys).
		let token = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
		func document(_ body: String) -> Data { Data(body.utf8) }
		let valid = document(#"{"env":"preview","tok":"\#(token)","v":1}"#)

		// Document parsing.
		let parsed = R.attribution(from: valid)
		expect(parsed?.environment == "preview" && parsed?.token == token, "server document parses")
		expect(parsed?.fingerprint == R.sha256(valid), "fingerprint is the document hash")
		expect(R.attribution(from: document(#"{"env":"production","tok":"\#(token)","v":1}"#))?.environment == "production",
		       "production document parses")
		let invalid: [(String, String)] = [
			(#"{"env":"preview","tok":"\#(token)","v":1,"job":"x"}"#, "extra field"),
			(#"{"env":"preview","tok":"\#(token)"}"#, "missing version"),
			(#"{"env":"preview","tok":"\#(token)","v":true}"#, "boolean version"),
			(#"{"env":"preview","tok":"\#(token)","v":1.0}"#, "float version"),
			(#"{"env":"preview","tok":"\#(token)","v":2}"#, "version 2"),
			(#"{"env":"staging","tok":"\#(token)","v":1}"#, "unknown environment"),
			(#"{"env":"preview","tok":"\#(token.dropLast())","v":1}"#, "42-character token"),
			(#"{"env":"preview","tok":"\#(token)A","v":1}"#, "44-character token"),
			(#"{"env":"preview","tok":"\#(token.dropLast())B","v":1}"#, "non-canonical final character"),
			(#"{"env":"preview","tok":"\#(token.dropLast())+","v":1}"#, "standard-base64 character"),
			("[1]", "not an object"), ("", "empty"), ("{", "truncated"),
		]
		for (body, label) in invalid {
			expect(R.attribution(from: document(body)) == nil, "refuses document: " + label)
		}
		expect(R.attribution(from: Data(repeating: 32, count: 300)) == nil, "refuses oversized document")

		// Metadata.
		let metadata = R.Metadata(appVersion: "1.0.0", appBuild: "1", osVersion: "26.1", deviceModel: "iPhone17,1")
		expect(R.isValid(metadata), "valid metadata")
		for (changed, label) in [
			(R.Metadata(appVersion: "1.0-beta", appBuild: "1", osVersion: "26.1", deviceModel: "iPhone17,1"), "version text"),
			(R.Metadata(appVersion: "1.0.0", appBuild: "", osVersion: "26.1", deviceModel: "iPhone17,1"), "empty build"),
			(R.Metadata(appVersion: "1.0.0", appBuild: "1", osVersion: "26.1", deviceModel: "arm64"), "simulator host model"),
			(R.Metadata(appVersion: "1.0.0", appBuild: "1", osVersion: "26.1", deviceModel: "Petar's iPhone"), "device name"),
		] {
			expect(!R.isValid(changed), "refuses metadata: " + label)
		}

		// Request body.
		let launch = Date(timeIntervalSince1970: 1_794_470_400)  // 2026-11-12 08:00:00 UTC
		let body = R.requestBody(attribution: parsed!, metadata: metadata, firstLaunch: launch)
		let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
		expect(Set(object.keys) == ["v", "attribution", "app_version", "app_build", "os_version", "device_model", "launched_at"],
		       "request has exactly the schema fields")
		expect(object["launched_at"] as? String == "2026-11-12 08:00:00", "launch time in UTC")
		expect(!String(decoding: body, as: UTF8.self).contains("identifierForVendor"), "no identifiers")
		if let out = ProcessInfo.processInfo.environment["ZAG_FIRST_LAUNCH_BODY_OUT"] {
			try? body.write(to: URL(fileURLWithPath: out))
		}

		// Planning.
		let t0 = Date(timeIntervalSince1970: 1_794_470_400)
		var (state, step) = R.plan(attribution: parsed, state: nil, completed: false, now: t0)
		expect(step == .send && state?.attempts == 0 && state?.firstLaunch == t0, "first launch sends")
		expect(R.plan(attribution: nil, state: state, completed: false, now: t0).1 == .none,
		       "no document (self-update, other build): nothing")
		expect(R.plan(attribution: nil, state: state, completed: false, now: t0).0 == state,
		       "no document leaves the state alone")
		expect(R.plan(attribution: parsed, state: nil, completed: true, now: t0).1 == .none,
		       "local file lost but Keychain says done: nothing")

		// Responses.
		var delivered = R.record(.status(202, retryAfter: nil), in: state!, now: t0)
		expect(delivered.outcome == .delivered && delivered.attempts == 1, "202 delivers")
		expect(R.plan(attribution: parsed, state: delivered, completed: false, now: t0.addingTimeInterval(9_999)).1 == .none,
		       "subsequent launches send nothing")
		for code in [400, 404, 405, 411, 413, 415] {
			expect(R.record(.status(code, retryAfter: nil), in: state!, now: t0).outcome == .rejected, "\(code) stops")
		}
		let limited = R.record(.status(429, retryAfter: 600), in: state!, now: t0)
		expect(limited.outcome == nil && limited.nextAttempt == t0.addingTimeInterval(600), "429 waits Retry-After")
		let busy = R.record(.status(503, retryAfter: 30), in: state!, now: t0)
		expect(busy.nextAttempt == t0.addingTimeInterval(60), "Retry-After never shortens the schedule")
		expect(R.record(.status(503, retryAfter: 1e9), in: state!, now: t0).nextAttempt == t0.addingTimeInterval(86_400),
		       "Retry-After capped at a day")
		let offline = R.record(.transportFailure, in: state!, now: t0)
		expect(offline.nextAttempt == t0.addingTimeInterval(60) && offline.outcome == nil, "offline retries later")
		(state, step) = R.plan(attribution: parsed, state: offline, completed: false, now: t0.addingTimeInterval(30))
		expect(step == .wait(until: t0.addingTimeInterval(60)), "backoff respected")
		expect(R.plan(attribution: parsed, state: offline, completed: false, now: t0.addingTimeInterval(61)).1 == .send,
		       "retry after backoff")

		// Bounded attempts and token lifetime.
		var failing = R.plan(attribution: parsed, state: nil, completed: false, now: t0).0!
		var sends = 0
		var now = t0
		while sends < 50 {
			let (planned, next) = R.plan(attribution: parsed, state: failing, completed: false, now: now)
			failing = planned!
			if case .wait(let until) = next { now = until; continue }
			guard next == .send else { break }
			sends += 1
			failing = R.record(.transportFailure, in: failing, now: now)
		}
		expect(sends == R.maxAttempts && failing.outcome == .gaveUp, "at most \(R.maxAttempts) attempts")
		var late = R.plan(attribution: parsed, state: nil, completed: false, now: t0).0!
		late.nextAttempt = nil
		let (expired, expiredStep) = R.plan(attribution: parsed, state: late, completed: false,
		                                    now: t0.addingTimeInterval(R.tokenLifetime + 1))
		expect(expiredStep == .none && expired?.outcome == .gaveUp, "nothing sent after the token lifetime")

		// Offline: no network uses no attempt and waits for a later launch.
		expect(R.response(for: .notConnectedToInternet) == .unreachable
		       && R.response(for: .dataNotAllowed) == .unreachable
		       && R.response(for: .internationalRoamingOff) == .unreachable, "no network is unreachable")
		expect(R.response(for: .timedOut) == .transportFailure && R.response(for: .cannotFindHost) == .transportFailure
		       && R.response(for: .secureConnectionFailed) == .transportFailure, "network failures use an attempt")
		let fresh0 = R.plan(attribution: parsed, state: nil, completed: false, now: t0).0!
		let unreachable = R.record(.unreachable, in: fresh0, now: t0)
		expect(unreachable.attempts == 0 && unreachable.outcome == nil
		       && unreachable.nextAttempt == t0.addingTimeInterval(R.offlineRecheck), "offline keeps the attempt")
		// Offline for 10 days, launched every hour, then online: delivered with one request.
		var away = fresh0
		var clock = t0
		var requests = 0
		for _ in 0..<(10 * 24) {
			let (planned, next) = R.plan(attribution: parsed, state: away, completed: false, now: clock)
			away = planned!
			if next == .send { away = R.record(.unreachable, in: away, now: clock) }
			clock = clock.addingTimeInterval(3600)
		}
		expect(away.attempts == 0 && away.outcome == nil, "ten days offline: no attempt used, not given up")
		let (back, backStep) = R.plan(attribution: parsed, state: away, completed: false, now: clock)
		if backStep == .send { requests += 1; away = R.record(.status(202, retryAfter: nil), in: back!, now: clock) }
		expect(requests == 1 && away.outcome == .delivered, "reports once back online")
		// Offline beyond the report window: given up without a request.
		let (stale, staleStep) = R.plan(attribution: parsed, state: unreachable, completed: false,
		                                now: t0.addingTimeInterval(R.reportWindow + 1))
		expect(staleStep == .none && stale?.outcome == .gaveUp, "nothing sent after the report window")
		expect(R.reportWindow < R.tokenLifetime, "report window inside the token validity")
		expect(R.maxAttempts == 10 && R.retryDelays.reduce(0, +) < R.reportWindow,
		       "ten requests at most, all inside the report window")

		// A newly signed IPA installed over the app is a new job's first launch.
		let other = R.attribution(from: document(#"{"env":"production","tok":"\#(token)","v":1}"#))
		let (fresh, freshStep) = R.plan(attribution: other, state: delivered, completed: false, now: t0)
		expect(freshStep == .send && fresh?.fingerprint == other?.fingerprint && fresh?.attempts == 0,
		       "different IPA starts afresh")

		// Durable store: file plus Keychain, with a disposable namespace.
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("zag-first-launch-\(UUID().uuidString)")
		let service = "app.zagstore.ios.first-launch-test.\(UUID().uuidString)"
		let store = ZagFirstLaunchStore(directory: directory, keychainService: service)
		defer {
			try? FileManager.default.removeItem(at: directory)
			SecItemDelete([kSecClass as String: kSecClassGenericPassword,
			               kSecAttrService as String: service] as CFDictionary)
		}
		expect(store.load() == nil, "empty store")
		try? store.save(offline)
		expect(store.load() == offline, "state round trip")
		expect(!store.isCompleted(offline.fingerprint), "pending is not completed")
		delivered.attempts = 1
		try? store.save(delivered)
		expect(store.isCompleted(delivered.fingerprint), "Keychain records the finished document")
		let backup = (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
		expect(backup == true, "state folder excluded from backups")
		try? FileManager.default.removeItem(at: directory)
		let afterLoss = R.plan(attribution: parsed, state: store.load(), completed: store.isCompleted(parsed!.fingerprint), now: t0)
		expect(afterLoss.1 == .none, "after local state loss, a finished document is not re-sent")

		print(failures == 0 ? "All first-launch report tests passed" : "\(failures) failed")
		exit(failures == 0 ? 0 : 1)
	}
}

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
		expect(R.attribution(from: document(#"{"env":"production","tok":"\#(token)","v":1}"#)) == nil,
		       "production document ignored (production reporting disabled)")
		expect(R.endpoints == ["preview": URL(string: "https://preview.zagstore.app/api/zag/v1/first-launch")!],
		       "only the preview endpoint exists")
		expect(R.attribution(from: document(#"{"v":1,"tok":"\#(token)","env":"preview"}"#)) != nil,
		       "key order does not matter")
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
			(#"{"env":"preview","tok":"\#(token)=","v":1}"#, "padded token"),
			(#"{"env":"preview","tok":" \#(token.dropFirst())","v":1}"#, "space in token"),
			(#"{"env":"preview","tok":7,"v":1}"#, "numeric token"),
			(#"{"env":"Preview","tok":"\#(token)","v":1}"#, "environment case"),
			(#"{"env":"preview","tok":"\#(token)","v":"1"}"#, "string version"),
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
		let sentDocument = object["attribution"] as? [String: Any] ?? [:]
		expect(Set(sentDocument.keys) == ["v", "env", "tok"] && sentDocument["env"] as? String == "preview"
		       && sentDocument["tok"] as? String == token && (sentDocument["v"] as? Int) == 1,
		       "request carries the document unchanged")
		expect(object["v"] as? Int == 1 && object["app_version"] as? String == "1.0.0" && object["app_build"] as? String == "1"
		       && object["os_version"] as? String == "26.1" && object["device_model"] as? String == "iPhone17,1",
		       "request carries the metadata")
		expect(body.count <= 1024, "request fits the server's 1 KB limit")
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
		expect(R.record(.status(429, retryAfter: nil), in: state!, now: t0).nextAttempt == t0.addingTimeInterval(60),
		       "429 without Retry-After uses the schedule")
		let unavailable = R.record(.status(503, retryAfter: nil), in: state!, now: t0)
		expect(unavailable.outcome == nil && unavailable.attempts == 1 && unavailable.nextAttempt == t0.addingTimeInterval(60),
		       "503 retries later")
		expect(R.record(.status(500, retryAfter: nil), in: state!, now: t0).outcome == nil, "500 retries later")
		expect(R.record(.status(200, retryAfter: nil), in: state!, now: t0).outcome == nil, "only 202 counts as delivered")
		let timedOut = R.record(R.response(for: .timedOut), in: state!, now: t0)
		expect(timedOut.outcome == nil && timedOut.attempts == 1 && timedOut.nextAttempt == t0.addingTimeInterval(60),
		       "timeout uses one attempt and retries later")
		let second = R.record(.status(503, retryAfter: nil), in: unavailable, now: t0.addingTimeInterval(60))
		expect(second.nextAttempt == t0.addingTimeInterval(60 + 300), "backoff grows")
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
		let other = R.attribution(from: document(#"{"env":"preview","tok":"BAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","v":1}"#))
		let (fresh, freshStep) = R.plan(attribution: other, state: delivered, completed: false, now: t0)
		expect(other != nil && freshStep == .send && fresh?.fingerprint == other?.fingerprint && fresh?.attempts == 0,
		       "different IPA starts afresh")
		expect(R.plan(attribution: other, state: delivered, completed: true, now: t0).1 == .none,
		       "a finished document is not re-sent after reinstall")

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

		// Report v2 (the website's REPORT-V2.md §1-2).
		func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
		let idPattern = #"^[A-Za-z0-9_-]{22}$"#
		let ids = (0..<64).map { _ in R.newReportID() }
		expect(ids.allSatisfy { $0.range(of: idPattern, options: .regularExpression) != nil }, "report id: 22 base64url characters")
		expect(Set(ids).count == ids.count, "report ids are random")
		let v2 = R.plan(attribution: parsed, state: nil, completed: false, now: t0, newID: { "AAAAAAAAAAAAAAAAAAAAAA" }).0!
		expect(v2.version == 2 && v2.reportID == "AAAAAAAAAAAAAAAAAAAAAA" && v2.jailbreak == false && v2.kind == nil,
		       "a new report is v2, jailbreak not included by default")
		let v2Body = R.requestBody(for: v2, attribution: parsed!, metadata: metadata, osBuild: "23B85", jailbreak: nil)
		let v2Object = json(v2Body)
		expect(Set(v2Object.keys) == ["v", "kind", "report_id", "attribution", "app_version", "app_build", "os_version",
		                              "device_model", "launched_at", "os_build"]
		       && v2Object["v"] as? Int == 2 && v2Object["kind"] as? String == "launch"
		       && v2Object["report_id"] as? String == "AAAAAAAAAAAAAAAAAAAAAA" && v2Object["os_build"] as? String == "23B85",
		       "v2 launch report: the v1 fields plus kind, report id and OS build")
		let detected = R.Jailbreak(status: .detected, layout: .rootless)
		expect(json(R.requestBody(for: v2, attribution: parsed!, metadata: metadata, osBuild: "23B85", jailbreak: detected))["jailbreak"] == nil,
		       "no jailbreak result unless the report was created with sharing on")
		for build in ["", "23b85", "23B85xy", "123B85", "B85", "23B"] {
			expect(json(R.requestBody(for: v2, attribution: parsed!, metadata: metadata, osBuild: build, jailbreak: nil))["os_build"] == nil,
			       "invalid OS build left out: \"\(build)\"")
		}
		expect(R.isOSBuild("22G5054d") && R.isOSBuild("23B85"), "OS build pattern (release and beta)")
		let withJailbreak = R.plan(attribution: parsed, state: nil, completed: false, now: t0, includeJailbreak: true).0!
		expect(withJailbreak.jailbreak == true, "sharing on when the report is created: included")
		let jbLaunch = R.requestBody(for: withJailbreak, attribution: parsed!, metadata: metadata, osBuild: "23B85", jailbreak: detected)
		let jbObject = json(jbLaunch)["jailbreak"] as? [String: Any] ?? [:]
		expect(Set(jbObject.keys) == ["consent", "status", "layout", "checks"] && jbObject["consent"] as? String == "opt_in"
		       && jbObject["status"] as? String == "detected" && jbObject["layout"] as? String == "rootless"
		       && jbObject["checks"] as? Int == R.detectorVersion,
		       "jailbreak: consent, status, layout and detector version only")
		let clean = R.jailbreakObject(R.Jailbreak(status: .notDetected, layout: .rootful))
		expect(Set(clean.keys) == ["consent", "status", "checks"] && clean["status"] as? String == "not_detected",
		       "layout only with detected")
		expect(R.classify(rootless: true, rootful: false, inspected: true) == R.Jailbreak(status: .detected, layout: .rootless)
		       && R.classify(rootless: false, rootful: true, inspected: true) == R.Jailbreak(status: .detected, layout: .rootful)
		       && R.classify(rootless: true, rootful: true, inspected: true) == R.Jailbreak(status: .detected, layout: nil)
		       && R.classify(rootless: false, rootful: false, inspected: true) == R.Jailbreak(status: .notDetected, layout: nil)
		       && R.classify(rootless: true, rootful: true, inspected: false) == R.Jailbreak(status: .unknown, layout: nil),
		       "classification")
		for body in [v2Body, jbLaunch] { expect(body.count <= 1024, "v2 report fits the server's 1 KB limit") }

		// The same report id for every retry; a new one only for a new report.
		let retried = R.record(.status(503, retryAfter: nil), in: withJailbreak, now: t0)
		let (again, againStep) = R.plan(attribution: parsed, state: retried, completed: false, now: t0.addingTimeInterval(61))
		expect(againStep == .send && again?.reportID == withJailbreak.reportID && again?.jailbreak == true,
		       "a retry keeps the report id and what it carries")

		// unsupported_version: the only answer that falls back, to v1.
		expect(R.response(status: 400, body: Data(#"{"status":"unsupported_version","supported_versions":[1]}"#.utf8), retryAfter: nil)
		       == .unsupportedVersion, "400 unsupported_version recognised")
		expect(R.response(status: 400, body: Data(#"{"status":"invalid"}"#.utf8), retryAfter: nil) == .status(400, retryAfter: nil)
		       && R.response(status: 202, body: Data(), retryAfter: nil) == .status(202, retryAfter: nil),
		       "any other answer counts by its status")
		let fellBack = R.record(.unsupportedVersion, in: withJailbreak, now: t0)
		expect(fellBack.version == 1 && fellBack.reportID == nil && fellBack.jailbreak == false && fellBack.outcome == nil
		       && fellBack.attempts == 1 && fellBack.nextAttempt == nil, "unsupported_version: v1 next, at once")
		expect(R.plan(attribution: parsed, state: fellBack, completed: false, now: t0).1 == .send, "the v1 report is sent")
		let v1Again = json(R.requestBody(for: fellBack, attribution: parsed!, metadata: metadata, osBuild: "23B85", jailbreak: detected))
		expect(Set(v1Again.keys) == ["v", "attribution", "app_version", "app_build", "os_version", "device_model", "launched_at"]
		       && v1Again["v"] as? Int == 1, "the fallback is exactly the v1 report (no OS build, no jailbreak)")
		expect(R.record(.unsupportedVersion, in: fellBack, now: t0).outcome == .rejected, "v1 refused too: stop")
		expect(R.record(.status(400, retryAfter: nil), in: withJailbreak, now: t0).outcome == .rejected, "400 invalid stays final")

		// A report started by an earlier build stays v1.
		let legacy = try? JSONDecoder().decode(R.State.self, from: Data(#"{"fingerprint":"f","firstLaunch":0,"attempts":2}"#.utf8))
		expect(legacy?.version == nil && legacy?.attempts == 2, "earlier builds' state still loads")
		expect(json(R.requestBody(for: legacy!, attribution: parsed!, metadata: metadata, osBuild: "23B85", jailbreak: nil))["v"] as? Int == 1,
		       "and is finished as v1")

		// The separate jailbreak report.
		let later = t0.addingTimeInterval(86_400)
		let jb = R.plan(attribution: parsed, state: nil, completed: false, now: later, kind: .jailbreak, start: t0).0!
		expect(jb.kind == .jailbreak && jb.version == 2 && jb.reportID != nil && jb.firstLaunch == t0,
		       "jailbreak report: v2, own id, window from the first launch")
		let jbBody = R.requestBody(for: jb, attribution: parsed!, metadata: metadata, osBuild: "23B85",
		                           jailbreak: R.Jailbreak(status: .unknown, layout: nil))
		let jbReport = json(jbBody)
		expect(Set(jbReport.keys) == ["v", "kind", "report_id", "attribution", "jailbreak"] && jbReport["kind"] as? String == "jailbreak",
		       "jailbreak report: no device metadata, no OS build")
		expect(R.requestBody(for: jb, attribution: parsed!, metadata: metadata, osBuild: nil, jailbreak: nil).isEmpty,
		       "no jailbreak report without a classification")
		expect(R.record(.unsupportedVersion, in: jb, now: later).outcome == .rejected, "a jailbreak report has no v1 form")
		let (jbLate, jbLateStep) = R.plan(attribution: parsed, state: jb, completed: false, now: t0.addingTimeInterval(R.reportWindow + 1),
		                                  kind: .jailbreak, start: t0)
		expect(jbLateStep == .none && jbLate?.outcome == .gaveUp, "no jailbreak report after the report window")
		if let out = ProcessInfo.processInfo.environment["ZAG_FIRST_LAUNCH_V2_BODIES_OUT"] {
			try? v2Body.write(to: URL(fileURLWithPath: out + "/launch.json"))
			try? jbLaunch.write(to: URL(fileURLWithPath: out + "/launch-jailbreak.json"))
			try? jbBody.write(to: URL(fileURLWithPath: out + "/jailbreak.json"))
		}

		// The jailbreak report's own file and Keychain record.
		let jbStore = ZagFirstLaunchStore(directory: directory, keychainService: service, kind: .jailbreak)
		let launchStore = ZagFirstLaunchStore(directory: directory, keychainService: service)
		var finishedJB = jb
		finishedJB.outcome = .delivered
		try? jbStore.save(finishedJB)
		expect(jbStore.load() == finishedJB && launchStore.load() != finishedJB, "separate state files")
		expect(jbStore.isCompleted(parsed!.fingerprint), "jailbreak report recorded as finished")
		let otherFingerprint = String(repeating: "e", count: 64)
		jbStore.markCompleted(otherFingerprint)
		expect(!launchStore.isCompleted(otherFingerprint), "a finished jailbreak report does not finish the launch report")
		launchStore.markCompleted(String(repeating: "d", count: 64))
		expect(!jbStore.isCompleted(String(repeating: "d", count: 64)), "and the other way round")
		try? FileManager.default.removeItem(at: directory)

		print(failures == 0 ? "All first-launch report tests passed" : "\(failures) failed")
		exit(failures == 0 ? 0 : 1)
	}
}

import Foundation

// Compiled with Feather/Utilities/ZagActivityReport.swift by
// scripts/test-zag-activity-report.sh. No app state is read or changed.

@main struct ZagActivityReportTests {
	static func main() {
		var failures = 0
		func expect(_ condition: Bool, _ label: String) {
			print((condition ? "PASS  " : "FAIL  ") + label)
			if !condition { failures += 1 }
		}
		typealias R = ZagActivityReport
		let start = Date(timeIntervalSince1970: 1_800_000_000)
		var ids = ["AAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBA", "CCCCCCCCCCCCCCCCCCCCCA"]
		func nextID() -> String { ids.removeFirst() }

		// Routing.
		expect(R.environment(attribution: "preview", testBuild: false) == "preview", "preview-signed copy reports to preview")
		expect(R.environment(attribution: "production", testBuild: true) == "production", "production-signed copy reports to production")
		expect(R.environment(attribution: nil, testBuild: false) == "production", "unattributed copy reports to production")
		expect(R.environment(attribution: "staging", testBuild: false) == "production", "unknown environment is not used")
		expect(R.environment(attribution: nil, testBuild: true) == "preview", "only the test build routes unattributed copies to preview")
		expect(R.endpoints == ["preview": URL(string: "https://preview.zagstore.app/api/zag/v1/activity")!,
		                       "production": URL(string: "https://zagstore.app/api/zag/v1/activity")!],
		       "exactly the two website endpoints")

		// Session ids.
		let generated = (0..<200).map { _ in R.newSessionID() }
		expect(generated.allSatisfy(R.isSessionID), "generated session ids are 22 base64url characters (128 bits)")
		expect(Set(generated).count == generated.count, "session ids are random")
		expect(!R.isSessionID("AAAAAAAAAAAAAAAAAAAAAB") && !R.isSessionID("short") && !R.isSessionID("AAAAAAAAAAAAAAAAAAAA/A"),
		       "malformed session ids refused")

		// Lifecycle: start, heartbeats, end.
		var session = R.Session()
		expect(session.heartbeat() == nil, "no heartbeat before a session")
		expect(session.enteredBackground(now: start) == nil, "no end before a session")
		let first = session.becameActive(now: start, newID: nextID)
		expect(first == .init(event: .start, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 0), "launch starts a session")
		expect(session.becameActive(now: start.addingTimeInterval(5), newID: nextID) == nil,
		       "becoming active again without a background changes nothing")
		expect(session.heartbeat() == .init(event: .heartbeat, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 1), "heartbeat in the foreground")
		expect(session.enteredBackground(now: start.addingTimeInterval(60))
		       == .init(event: .end, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 2), "background ends the session")
		expect(session.heartbeat() == nil, "no heartbeat in the background")
		expect(session.enteredBackground(now: start.addingTimeInterval(61)) == nil, "end sent once")

		// Renewal: a short interruption continues, five minutes starts anew.
		let resumed = session.becameActive(now: start.addingTimeInterval(60 + 299), newID: nextID)
		expect(resumed == .init(event: .heartbeat, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 3),
		       "under five minutes in the background continues the session")
		_ = session.enteredBackground(now: start.addingTimeInterval(400))
		let renewed = session.becameActive(now: start.addingTimeInterval(400 + 300), newID: nextID)
		expect(renewed == .init(event: .start, session: "BBBBBBBBBBBBBBBBBBBBBA", sequence: 0),
		       "five minutes in the background starts a new session")
		_ = session.enteredBackground(now: start.addingTimeInterval(800))
		expect(session.becameActive(now: start.addingTimeInterval(700), newID: nextID)?.event == .start,
		       "a clock moved backwards starts a new session")

		// Opt-out / server stop forget the session.
		session.reset()
		expect(session == R.Session() && session.heartbeat() == nil && session.enteredBackground(now: start) == nil,
		       "reset forgets the session; nothing more to send")

		// Request body.
		let metadata = R.Metadata(appVersion: "1.0.0", appBuild: "3", osVersion: "26.1")
		let body = R.requestBody(.init(event: .start, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 0), metadata: metadata)
		let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
		expect(Set(object?.keys.map { $0 } ?? []) == ["v", "event", "session", "seq", "app_version", "app_build", "os_version"],
		       "body has exactly the schema fields")
		expect(object?["v"] as? Int == 1 && object?["event"] as? String == "start" && object?["seq"] as? Int == 0,
		       "body values")
		expect(body.count <= R.maxBodyBytes, "body within the size limit (\(body.count) bytes)")
		expect(R.requestBody(.init(event: .start, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 0),
		                     metadata: .init(appVersion: "1.0.0-beta", appBuild: "3", osVersion: "26.1")).isEmpty,
		       "metadata the server would refuse is never sent")
		expect(R.requestBody(.init(event: .start, session: "bad", sequence: 0), metadata: metadata).isEmpty,
		       "invalid session id is never sent")
		if let out = ProcessInfo.processInfo.environment["ZAG_ACTIVITY_BODIES_OUT"] {
			try? body.write(to: URL(fileURLWithPath: out + "/start.json"))
			try? R.requestBody(.init(event: .heartbeat, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 1), metadata: metadata)
				.write(to: URL(fileURLWithPath: out + "/heartbeat.json"))
			try? R.requestBody(.init(event: .end, session: "AAAAAAAAAAAAAAAAAAAAAA", sequence: 2), metadata: metadata)
				.write(to: URL(fileURLWithPath: out + "/end.json"))
		}

		// Responses.
		expect(R.outcome(status: 202, retryAfter: nil) == .carryOn, "202 carries on")
		expect(R.outcome(status: 410, retryAfter: nil) == .stop, "410 (server switch off) stops for this launch")
		expect([400, 404, 405, 413, 415].allSatisfy { R.outcome(status: $0, retryAfter: nil) == .stop },
		       "refusals stop for this launch")
		expect(R.outcome(status: 429, retryAfter: 120) == .pause(120), "429 pauses for Retry-After")
		expect(R.outcome(status: 503, retryAfter: 86_400) == .pause(R.maxPause), "pause is bounded")
		expect(R.outcome(status: 429, retryAfter: nil) == .pause(R.defaultPause), "pause without Retry-After")
		expect(R.outcome(status: 500, retryAfter: nil) == .carryOn, "server error: no retry, the next heartbeat stands in")

		if failures > 0 { print("\(failures) failed"); exit(1) }
	}
}

import Foundation

// Compiled with Feather/Utilities/ZagSelfUpdateRetryPolicy.swift by
// scripts/test-zag-self-update-recovery.sh.
@main struct ZagSelfUpdateRetryPolicyTests {
	static func main() {
		typealias Policy = ZagSelfUpdateRetryPolicy
		var failures = 0
		func expect(_ condition: Bool, _ label: String) {
			print((condition ? "PASS  " : "FAIL  ") + label)
			if !condition { failures += 1 }
		}
		func e(_ code: Int32, _ message: String = "") -> ZagGate4Event { ZagGate4Event(code: code, message: message) }
		func safe(_ events: [ZagGate4Event]?) -> Bool { Policy.progress(afterEvents: events) == .failedBeforeUpgradeRequest }
		func held(_ events: [ZagGate4Event]?) -> Bool { Policy.progress(afterEvents: events) == .ambiguous }

		let connected = [e(201), e(202), e(203), e(204)]
		let streamed = e(205, "Upgrading com.cwd43.gu29")
		let helper = e(205, "Upgrading app.zagstore.ios")
		let failed = e(-4, "Gate4 failed")

		// Provably before the Upgrade request.
		expect(safe([e(201), failed]), "failure right after start is safe")
		expect(safe([e(201), e(202), failed]), "failure while connecting is safe")
		expect(safe(connected + [failed]), "failure after RSD, before 205, is safe")
		expect(safe(connected + [streamed, failed]), "streamed path failing before upload is safe")
		expect(safe(connected + [streamed, e(208, "1"), e(208, "57"), failed]), "streamed partial upload is safe")
		expect(safe(connected + [streamed, e(208, "100"), failed]), "streamed upload finished but unverified (no 209) is safe")

		// Partial uploads on the helper path: Upgrade follows upload in one call.
		expect(held(connected + [helper, failed]), "canonical bundle failing after 205 is ambiguous")
		expect(held(connected + [helper, e(206, "10"), failed]), "helper path with iOS progress is ambiguous")
		expect(held(connected + [e(205, "Installing com.cwd43.gu29"), failed]), "fresh-install announcement is ambiguous")
		expect(held(connected + [e(205, "Upgrading com.cwd43.gu29.extra"), failed]), "near-match bundle ID is ambiguous")

		// Ambiguous failures: Upgrade may have been sent.
		expect(held(connected + [streamed, e(208, "100"), e(209), failed]), "failure after full staging is ambiguous")
		expect(held(connected + [streamed, e(209), e(206, "40"), failed]), "failure after iOS progress is ambiguous")
		expect(held(connected + [streamed, e(210), failed]), "upgrade-transmitted code is ambiguous")
		expect(held(connected + [streamed, e(207), failed]), "completion before failure is ambiguous")
		expect(held(connected + [e(207)]), "an attempt ending in completion is never released")

		// Unknown callbacks.
		expect(held([e(201), e(211), failed]), "unknown 211 is ambiguous")
		expect(held([e(201), e(999), failed]), "unknown 999 is ambiguous")
		expect(held(connected + [streamed, e(208, "5"), e(0), failed]), "unknown code during upload is ambiguous")

		// Missing callbacks.
		expect(held(nil), "no terminal snapshot is ambiguous")
		expect(held([]), "no callbacks at all is ambiguous")
		expect(held([failed]), "failure without 201 is ambiguous")
		expect(held([e(201), e(203), failed]), "skipped connection stage is ambiguous")
		expect(held([e(201), e(202), e(203), streamed, failed]), "205 before RSD is ambiguous")
		expect(held(connected + [e(208, "5"), failed]), "upload progress without 205 is ambiguous")
		expect(held(connected + [e(205), failed]), "205 without a message is ambiguous")

		// Reordered, duplicated, malformed or late callbacks.
		expect(held([e(202), e(201), failed]), "reordered connection stages are ambiguous")
		expect(held([e(201), e(202), e(202), failed]), "duplicated stage is ambiguous")
		expect(held(connected + [streamed, e(208, "50"), e(208, "20"), failed]), "upload progress going backwards is ambiguous")
		expect(held(connected + [streamed, e(208, "50"), e(208, "50"), failed]), "repeated upload progress is ambiguous")
		expect(held(connected + [streamed, e(208, "abc"), failed]), "non-numeric upload progress is ambiguous")
		expect(held(connected + [streamed, e(208, "101"), failed]), "upload progress over 100 is ambiguous")
		expect(held(connected + [failed, e(206, "10")]), "callback after failure is ambiguous")
		expect(held(connected + [failed, failed]), "two failures are ambiguous")
		expect(held([e(201), failed, e(202), failed]), "failure in the middle is ambiguous")

		// Release decisions.
		expect(Policy.mayReleasePendingRecord(after: .notStarted), "release when installer never started")
		expect(Policy.mayReleasePendingRecord(after: .failedBeforeUpgradeRequest), "release when proven before Upgrade")
		expect(!Policy.mayReleasePendingRecord(after: .ambiguous), "keep record when ambiguous")

		if failures > 0 {
			print("\(failures) test(s) failed")
			exit(1)
		}
		print("All retry policy tests passed")
	}
}

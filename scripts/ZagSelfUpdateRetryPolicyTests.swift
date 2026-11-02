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

		// Progress classification from real Gate4 callback sequences.
		expect(Policy.progress(afterCallbackCodes: []) == .notStarted, "no callbacks means not started")
		expect(Policy.progress(afterCallbackCodes: [201, 202, 203, 204]) == .uploadOnly, "failure while connecting is upload-only")
		expect(Policy.progress(afterCallbackCodes: [201, 202, 203, 204, 205, 208, 208, -4]) == .uploadOnly, "failure during upload is upload-only")
		expect(Policy.progress(afterCallbackCodes: [201, 205, 208, 209, -4]) == .upgradeMayHaveBeenSubmitted, "failure after full staging is ambiguous")
		expect(Policy.progress(afterCallbackCodes: [201, 205, 208, 209, 206, -4]) == .upgradeMayHaveBeenSubmitted, "failure after iOS progress is ambiguous")
		expect(Policy.progress(afterCallbackCodes: [201, 206]) == .upgradeMayHaveBeenSubmitted, "any iOS progress is ambiguous")
		expect(Policy.progress(afterCallbackCodes: [210]) == .upgradeMayHaveBeenSubmitted, "upgrade transmitted is ambiguous")
		expect(Policy.progress(afterCallbackCodes: [207]) == .upgradeMayHaveBeenSubmitted, "completion is never released as a failure")

		// Release decisions.
		expect(Policy.mayReleasePendingRecord(after: .notStarted), "release when installer never started")
		expect(Policy.mayReleasePendingRecord(after: .uploadOnly), "release when only uploading")
		expect(!Policy.mayReleasePendingRecord(after: .upgradeMayHaveBeenSubmitted), "keep record when upgrade may be in progress")

		if failures > 0 {
			print("\(failures) test(s) failed")
			exit(1)
		}
		print("All retry policy tests passed")
	}
}

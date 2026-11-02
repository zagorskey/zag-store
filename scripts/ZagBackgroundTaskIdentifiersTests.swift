import Foundation

// Compiled with Feather/Utilities/ZagBackgroundTaskIdentifiers.swift by
// scripts/test-zag-background-refresh.sh.
@main struct ZagBackgroundTaskIdentifiersTests {
	static func main() {
		typealias IDs = ZagBackgroundTaskIdentifiers
		var failures = 0
		func expect(_ condition: Bool, _ label: String) {
			print((condition ? "PASS  " : "FAIL  ") + label)
			if !condition { failures += 1 }
		}

		expect(IDs.continuedDownloadPrefix(permitted: [
			"com.cwd43.gu29.background-update-check",
			"app.zagstore.ios.userTask.*"
		]) == "app.zagstore.ios.userTask.", "uses the permitted userTask wildcard")
		expect(IDs.continuedDownloadPrefix(permitted: [
			"com.cwd43.gu29.background-update-check"
		]) == nil, "no wildcard means no continued-processing tasks")
		expect(IDs.continuedDownloadPrefix(permitted: []) == nil, "empty list means none")
		expect(IDs.continuedDownloadPrefix(permitted: [".userTask.*"]) == nil, "bare suffix is rejected")
		expect(IDs.continuedDownloadPrefix(permitted: [
			"$(PRODUCT_BUNDLE_IDENTIFIER).userTask.*"
		]) == "$(PRODUCT_BUNDLE_IDENTIFIER).userTask.", "unexpanded value is used verbatim (build check catches it)")

		if failures > 0 {
			print("\(failures) test(s) failed")
			exit(1)
		}
		print("All background identifier tests passed")
	}
}

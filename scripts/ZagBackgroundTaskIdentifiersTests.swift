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
		let shipped = ["com.cwd43.gu29.background-update-check", "app.zagstore.ios.userTask.*"]

		expect(IDs.continuedDownloadPrefix(permitted: shipped, bundleIdentifier: "app.zagstore.ios")
			== "app.zagstore.ios.userTask.", "uses the wildcard for the running bundle ID")
		expect(IDs.continuedDownloadPrefix(permitted: shipped, bundleIdentifier: "com.example.resigned") == nil,
			"re-signed bundle ID without its own wildcard falls back to foreground")
		expect(IDs.continuedDownloadPrefix(permitted: ["com.example.resigned.userTask.*"], bundleIdentifier: "com.example.resigned")
			== "com.example.resigned.userTask.", "a plist rewritten for the new bundle ID is honoured")
		expect(IDs.continuedDownloadPrefix(permitted: ["app.zagstore.ios.userTask.*"], bundleIdentifier: "app.zagstore")
			== nil, "bundle ID that is only a prefix does not match")
		expect(IDs.continuedDownloadPrefix(permitted: ["com.cwd43.gu29.background-update-check"], bundleIdentifier: "com.cwd43.gu29")
			== nil, "no wildcard means no continued-processing tasks")
		expect(IDs.continuedDownloadPrefix(permitted: [], bundleIdentifier: "app.zagstore.ios") == nil, "empty list means none")
		expect(IDs.continuedDownloadPrefix(permitted: shipped, bundleIdentifier: nil) == nil, "missing bundle ID means none")
		expect(IDs.continuedDownloadPrefix(permitted: [".userTask.*"], bundleIdentifier: "") == nil, "empty bundle ID means none")
		expect(IDs.continuedDownloadPrefix(permitted: ["$(PRODUCT_BUNDLE_IDENTIFIER).userTask.*"], bundleIdentifier: "app.zagstore.ios")
			== nil, "unexpanded build setting is never used")

		// Generated identifiers match the permitted wildcard.
		let prefix = IDs.continuedDownloadPrefix(permitted: shipped, bundleIdentifier: "app.zagstore.ios")!
		let generated = prefix + "0123456789abcdef0123456789abcdef"
		expect(generated.hasPrefix("app.zagstore.ios.userTask.") && !generated.dropFirst(prefix.count).contains("."),
			"generated identifier is <bundle>.userTask.<hash>")

		if failures > 0 {
			print("\(failures) test(s) failed")
			exit(1)
		}
		print("All background identifier tests passed")
	}
}

import Foundation

// Compiled with Feather/Utilities/ZagDeviceFamilyPolicy.swift by
// scripts/test-zag-self-update-recovery.sh.

@main struct ZagDeviceFamilyPolicyTests {
	static func main() {
		var failures = 0
		func expect(_ condition: Bool, _ label: String) {
			print((condition ? "PASS  " : "FAIL  ") + label)
			if !condition { failures += 1 }
		}
		typealias P = ZagDeviceFamilyPolicy

		/// UIDeviceFamily as the app reads it: decoded from a real Info.plist.
		func plistValue(_ xml: String) -> Any? {
			let document = """
			<?xml version="1.0" encoding="UTF-8"?>
			<plist version="1.0"><dict>\(xml)</dict></plist>
			"""
			let dictionary = try? PropertyListSerialization.propertyList(
				from: Data(document.utf8), options: [], format: nil) as? [String: Any]
			return dictionary?["UIDeviceFamily"]
		}
		let universal = P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>"))
		let iPhoneOnly = P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><array><integer>1</integer></array>"))
		let iPadOnly = P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><array><integer>2</integer></array>"))

		// Parsing.
		expect(universal == [1, 2], "universal Info.plist parses as [1, 2]")
		expect(iPhoneOnly == [1], "iPhone-only Info.plist parses as [1]")
		expect(iPadOnly == [2], "iPad-only Info.plist parses as [2]")
		expect(P.families(fromInfoPlistValue: nil) == [1], "missing UIDeviceFamily means iPhone only, as on iOS")
		expect(P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><integer>2</integer>")) == [2], "a single integer is accepted")
		expect(P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><array><string>1</string><string>2</string></array>")) == [1, 2], "numeric strings are accepted")
		expect(P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><array/>")) == nil, "empty array is malformed")
		expect(P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><array><string>iPad</string></array>")) == nil, "non-numeric string is malformed")
		expect(P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><true/>")) == nil, "boolean is malformed")
		expect(P.families(fromInfoPlistValue: plistValue("<key>UIDeviceFamily</key><array><real>1.5</real></array>")) == nil, "fractional number is malformed")

		// Hardware model identifiers (an iPhone app on iPad reports the phone idiom).
		expect(P.device(fromModelIdentifier: "iPhone16,2") == .phone, "iPhone model is phone")
		expect(P.device(fromModelIdentifier: "iPod9,1") == .phone, "iPod touch model is phone")
		expect(P.device(fromModelIdentifier: "iPad14,1") == .pad, "iPad model is pad")
		expect(P.device(fromModelIdentifier: "arm64") == .unknown, "Mac or simulator host is unknown")
		expect(P.device(fromModelIdentifier: nil) == .unknown, "missing model is unknown")

		// iPhone.
		expect(P.allowsReplacement(candidate: universal, installed: universal, device: .phone), "iPhone: universal over universal is allowed")
		expect(P.allowsReplacement(candidate: iPhoneOnly, installed: universal, device: .phone), "iPhone: iPhone-only over universal is allowed")
		expect(P.allowsReplacement(candidate: universal, installed: iPhoneOnly, device: .phone), "iPhone: universal over iPhone-only is allowed")
		expect(!P.allowsReplacement(candidate: iPadOnly, installed: universal, device: .phone), "iPhone: iPad-only build is rejected")
		expect(!P.allowsReplacement(candidate: iPadOnly, installed: iPhoneOnly, device: .phone), "iPhone: iPad-only over iPhone-only is rejected")

		// iPad running natively.
		expect(P.allowsReplacement(candidate: universal, installed: universal, device: .pad), "iPad: universal over universal is allowed")
		expect(P.allowsReplacement(candidate: iPadOnly, installed: universal, device: .pad), "iPad: iPad-only over universal is allowed")
		expect(P.allowsReplacement(candidate: universal, installed: iPadOnly, device: .pad), "iPad: universal over iPad-only is allowed")
		expect(!P.allowsReplacement(candidate: iPhoneOnly, installed: universal, device: .pad), "iPad: iPhone-only build is rejected (would drop to compatibility mode)")
		expect(!P.allowsReplacement(candidate: iPhoneOnly, installed: iPadOnly, device: .pad), "iPad: iPhone-only over iPad-only is rejected")
		expect(!P.allowsReplacement(candidate: iPhoneOnly, installed: nil, device: .pad), "iPad: unknown installed family is treated as native iPad")

		// iPad running an iPhone-only build in compatibility mode.
		expect(P.allowsReplacement(candidate: iPhoneOnly, installed: iPhoneOnly, device: .pad), "iPad compat: iPhone-only over iPhone-only is allowed")
		expect(P.allowsReplacement(candidate: universal, installed: iPhoneOnly, device: .pad), "iPad compat: universal restores native iPad")
		expect(P.allowsReplacement(candidate: iPadOnly, installed: iPhoneOnly, device: .pad), "iPad compat: iPad-only restores native iPad")

		// Unknown hardware never narrows support.
		expect(P.allowsReplacement(candidate: universal, installed: universal, device: .unknown), "unknown device: same families allowed")
		expect(!P.allowsReplacement(candidate: iPhoneOnly, installed: universal, device: .unknown), "unknown device: narrowing to iPhone rejected")
		expect(!P.allowsReplacement(candidate: iPadOnly, installed: universal, device: .unknown), "unknown device: narrowing to iPad rejected")
		expect(!P.allowsReplacement(candidate: universal, installed: nil, device: .unknown), "unknown device and installed family: rejected")

		// Malformed candidates always fail closed.
		for device in [P.Device.phone, .pad, .unknown] {
			expect(!P.allowsReplacement(candidate: nil, installed: universal, device: device), "malformed candidate rejected on \(device)")
			expect(!P.allowsReplacement(candidate: [], installed: universal, device: device), "empty candidate rejected on \(device)")
		}

		if failures > 0 {
			print("\(failures) test(s) failed")
			exit(1)
		}
		print("All device-family policy tests passed")
	}
}

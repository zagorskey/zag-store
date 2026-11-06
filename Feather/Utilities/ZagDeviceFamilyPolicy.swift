import Foundation

/// Decides whether a signed self-update candidate may replace the running
/// installation on this device, based on the candidate's UIDeviceFamily.
///
/// Why: an iPhone-only build (UIDeviceFamily [1]) installs on an iPad but
/// runs in iPhone compatibility mode, and an iPad-only build ([2]) cannot
/// install on an iPhone at all. Bundle ID, version, team and keychain
/// checks do not catch either case.
///
/// Rules:
/// - iPhone or iPod touch: the candidate must support iPhone (1).
/// - iPad: if the installed app runs natively on iPad (its family includes
///   2), the candidate must include 2 too, so native iPad support is never
///   lost. An installed iPhone-only app (compatibility mode) may be replaced
///   by any build that installs on iPad.
/// - Unknown hardware: the candidate must support every family the
///   installed app supports (never narrower).
///
/// Pure and Foundation-only so host-side tests can compile it directly.
enum ZagDeviceFamilyPolicy {
	enum Device: Equatable {
		case phone
		case pad
		case unknown
	}

	static let iPhone = 1
	static let iPad = 2

	/// Families from an Info.plist UIDeviceFamily value. iOS treats a
	/// missing value as iPhone only. Returns nil for a malformed value.
	static func families(fromInfoPlistValue value: Any?) -> Set<Int>? {
		guard let value else { return [iPhone] }
		let items: [Any] = (value as? [Any]) ?? [value]
		var result = Set<Int>()
		for item in items {
			if let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
				let double = number.doubleValue
				guard double == double.rounded(), let family = Int(exactly: double) else { return nil }
				result.insert(family)
			} else if let text = item as? String, let family = Int(text) {
				result.insert(family)
			} else {
				return nil
			}
		}
		return result.isEmpty ? nil : result
	}

	/// The device kind from a hardware model identifier, such as "iPad14,1"
	/// or "iPhone16,2". The hardware model is used because an iPhone app on
	/// an iPad reports the phone interface idiom.
	static func device(fromModelIdentifier model: String?) -> Device {
		guard let model else { return .unknown }
		if model.hasPrefix("iPad") { return .pad }
		if model.hasPrefix("iPhone") || model.hasPrefix("iPod") { return .phone }
		return .unknown
	}

	/// The running device, from hw.machine (or the simulated model).
	static func currentDevice() -> Device {
		if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
			return device(fromModelIdentifier: simulated)
		}
		var size = 0
		guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return .unknown }
		var bytes = [CChar](repeating: 0, count: size)
		guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return .unknown }
		return device(fromModelIdentifier: String(cString: bytes))
	}

	/// True if the candidate may replace the installation on this device.
	static func allowsReplacement(candidate: Set<Int>?, installed: Set<Int>?, device: Device) -> Bool {
		guard let candidate, !candidate.isEmpty else { return false }
		switch device {
		case .phone:
			return candidate.contains(iPhone)
		case .pad:
			if installed?.contains(iPad) ?? true {
				return candidate.contains(iPad)
			}
			return candidate.contains(iPhone) || candidate.contains(iPad)
		case .unknown:
			guard let installed, !installed.isEmpty else { return false }
			return installed.isSubset(of: candidate)
		}
	}
}

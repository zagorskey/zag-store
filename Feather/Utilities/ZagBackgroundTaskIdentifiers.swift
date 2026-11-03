import Foundation

/// Background task identifiers derived from what Info.plist actually permits.
///
/// Registering an identifier that is not listed in
/// BGTaskSchedulerPermittedIdentifiers fails, and a re-signed app can have a
/// different bundle identifier from the one the plist was built with. A
/// continued-processing task is used only when both agree.
enum ZagBackgroundTaskIdentifiers {
	static let permittedKey = "BGTaskSchedulerPermittedIdentifiers"
	static let continuedDownloadSuffix = ".userTask.*"

	/// The prefix for per-download continued-processing tasks
	/// ("<bundle ID>.userTask."), or nil when Info.plist does not permit it.
	///
	/// The BGContinuedProcessingTaskRequest header requires the identifier
	/// prefix to contain the submitting app's bundle ID. A re-signed copy
	/// whose bundle ID no longer matches the plist gets nil and downloads in
	/// the foreground only.
	static func continuedDownloadPrefix(permitted: [String], bundleIdentifier: String?) -> String? {
		guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
		let wildcard = bundleIdentifier + continuedDownloadSuffix
		guard permitted.contains(wildcard) else { return nil }
		return String(wildcard.dropLast())
	}

	static func continuedDownloadPrefix(in bundle: Bundle = .main) -> String? {
		let permitted = bundle.object(forInfoDictionaryKey: permittedKey) as? [String] ?? []
		return continuedDownloadPrefix(permitted: permitted, bundleIdentifier: bundle.bundleIdentifier)
	}
}

import Foundation

/// Background task identifiers derived from what Info.plist actually permits.
///
/// Registering an identifier that is not listed in
/// BGTaskSchedulerPermittedIdentifiers fails (and may raise), and a re-signed
/// app can have a different bundle identifier from the one the plist was built
/// with. Deriving identifiers from the permitted list avoids both problems.
enum ZagBackgroundTaskIdentifiers {
	static let permittedKey = "BGTaskSchedulerPermittedIdentifiers"
	static let continuedDownloadSuffix = ".userTask.*"

	/// The prefix for per-download continued-processing tasks, ending in
	/// ".userTask.", or nil when no matching wildcard is permitted.
	static func continuedDownloadPrefix(permitted: [String]) -> String? {
		guard let wildcard = permitted.first(where: {
			$0.hasSuffix(continuedDownloadSuffix) && $0.count > continuedDownloadSuffix.count
		}) else { return nil }
		return String(wildcard.dropLast())
	}

	static func continuedDownloadPrefix(in bundle: Bundle = .main) -> String? {
		let permitted = bundle.object(forInfoDictionaryKey: permittedKey) as? [String] ?? []
		return continuedDownloadPrefix(permitted: permitted)
	}
}

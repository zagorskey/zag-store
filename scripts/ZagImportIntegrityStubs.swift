import Foundation
import OSLog

// Minimal stand-ins for the app types the real AppFileHandler and
// FR.handlePackageFile use (scripts/test-zag-import-integrity.sh). Nothing
// here touches the importer's copy, verify or extract steps.

extension Logger {
	static let misc = Logger(subsystem: "app.zagstore.import-integrity-harness", category: "Misc")
}

/// Imported apps land in the harness's own directory, never in ~/Documents.
enum ImportHarnessPaths {
	static let root = FileManager.default.temporaryDirectory
		.appendingPathComponent("ZagImportIntegrity-\(UUID().uuidString)", isDirectory: true)
}

extension FileManager {
	func unsigned(_ uuid: String) -> URL {
		ImportHarnessPaths.root.appendingPathComponent("Unsigned/\(uuid)", isDirectory: true)
	}
}

class Download: @unchecked Sendable {
	var unpackageProgress = 0.0
	var overallProgress: Double { unpackageProgress }
}

final class BackgroundTaskManager {
	static let shared = BackgroundTaskManager()
	func updateProgress(for download: Download, progress: Double) {}
}

final class Storage {
	static let shared = Storage()
	/// UUIDs of every import that reached the database, in call order.
	var importedUUIDs: [String] = []

	func addImported(
		uuid: String,
		source: URL? = nil,
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		completion: @escaping (Error?) -> Void
	) {
		importedUUIDs.append(uuid)
		completion(nil)
	}
}

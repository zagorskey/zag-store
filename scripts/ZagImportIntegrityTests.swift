import Foundation
import CryptoKit
import Zip

// Focused tests for the real importer: AppFileHandler.swift, the real
// FR.handlePackageFile (extracted from FR.swift by the runner) and
// ZagPackageIntegrity.swift, compiled unchanged. The central property: when
// a signed SHA-256 is given, the only bytes ever extracted are bytes that
// match it, and a mismatch stops the import before extraction.

@main
struct ZagImportIntegrityTests {
	nonisolated(unsafe) static var failures = 0
	nonisolated(unsafe) static var passes = 0

	static func check(_ condition: Bool, _ message: String) {
		if condition { print("PASS: \(message)"); passes += 1 } else { print("FAIL: \(message)"); failures += 1 }
	}

	static func sha256(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	static let authentic = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) })
	static var tampered: Data { var data = authentic; data[1_234] ^= 0x01; return data }

	/// The importer's per-import working directories still on disk.
	static func workDirectories() -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
			.filter { $0.hasPrefix("FeatherImport_") }
	}

	static func importPackage(_ url: URL, expectedSHA256: String?) async -> (uuid: String?, error: Error?) {
		await withCheckedContinuation { continuation in
			var uuid: String?
			FR.handlePackageFile(url, expectedSHA256: expectedSHA256, importedUUID: { uuid = $0 }) { error in
				continuation.resume(returning: (uuid, error))
			}
		}
	}

	static func reset() {
		Zip.extractedDigests = []
		Zip.beforeExtracting = nil
		Storage.shared.importedUUIDs = []
	}

	static func main() async {
		setvbuf(stdout, nil, _IOLBF, 0)
		let fileManager = FileManager.default
		// The app creates its Unsigned directory at launch.
		try! fileManager.createDirectory(at: ImportHarnessPaths.root.appendingPathComponent("Unsigned"),
		                                 withIntermediateDirectories: true)
		defer { try? fileManager.removeItem(at: ImportHarnessPaths.root) }
		let staged = ImportHarnessPaths.root.appendingPathComponent("verified-release.ipa")
		let signed = sha256(authentic)
		let existingWorkDirectories = Set(workDirectories())
		func newWorkDirectories() -> [String] { workDirectories().filter { !existingWorkDirectories.contains($0) } }

		// 1. Authentic package with its signed digest: imported, and the bytes
		//    extracted are the authenticated bytes.
		reset()
		try! authentic.write(to: staged)
		var result = await importPackage(staged, expectedSHA256: signed)
		check(result.error == nil && result.uuid != nil && Storage.shared.importedUUIDs.count == 1,
		      "authentic package with its signed SHA-256 is imported (\(result.error.map { "\($0)" } ?? "ok"))")
		check(Zip.extractedDigests == [signed], "the extracted bytes are the authenticated bytes")
		check(newWorkDirectories().isEmpty, "a successful import removes its working directory")

		// 2. Upper-case digest is accepted.
		reset()
		result = await importPackage(staged, expectedSHA256: signed.uppercased())
		check(result.error == nil && Zip.extractedDigests == [signed], "upper-case signed SHA-256 is accepted")

		// 3. Mismatch: rejected before extraction, nothing recorded, nothing left.
		reset()
		try! tampered.write(to: staged)
		result = await importPackage(staged, expectedSHA256: signed)
		if case ZagPackageIntegrity.Failure.checksumMismatch? = result.error {
			check(true, "a package that does not match the signed SHA-256 is rejected (checksumMismatch)")
		} else {
			check(false, "a package that does not match the signed SHA-256 is rejected (\(result.error.map { "\($0)" } ?? "imported"))")
		}
		check(Zip.extractedDigests.isEmpty, "a mismatching package is never extracted")
		check(Storage.shared.importedUUIDs.isEmpty && result.uuid == nil, "a mismatching package never reaches the database")
		check(newWorkDirectories().isEmpty, "a rejected import removes its working directory")
		let unsignedApps = (try? fileManager.contentsOfDirectory(atPath: ImportHarnessPaths.root.appendingPathComponent("Unsigned").path)) ?? []
		check(unsignedApps.count == 2, "a rejected import adds no app directory (\(unsignedApps.count) from the two accepted imports)")

		// 4. Truncated and empty packages are rejected the same way.
		for (label, bytes) in [("a truncated", authentic.prefix(100_000)), ("an empty", Data())] {
			reset()
			try! Data(bytes).write(to: staged)
			result = await importPackage(staged, expectedSHA256: signed)
			check(result.error != nil && Zip.extractedDigests.isEmpty && Storage.shared.importedUUIDs.isEmpty,
			      "\(label) package is rejected before extraction")
		}

		// 5. The staged file is replaced while the import runs, after the
		//    importer copied it: extraction still reads the importer's own
		//    verified copy, never the shared staged file.
		reset()
		try! authentic.write(to: staged)
		var extractedArchive: URL?
		Zip.beforeExtracting = { archive in
			extractedArchive = archive
			try? tampered.write(to: staged)
		}
		result = await importPackage(staged, expectedSHA256: signed)
		check(result.error == nil && Zip.extractedDigests == [signed],
		      "replacing the staged file during import does not change the extracted bytes")
		check(extractedArchive.map { $0.standardizedFileURL != staged.standardizedFileURL
		                              && $0.deletingLastPathComponent().lastPathComponent.hasPrefix("FeatherImport_") } == true,
		      "the importer extracts its own working copy, not the staged file")

		// 6. Without a digest (repository downloads, files opened in the app)
		//    behaviour is unchanged: the package is imported as before.
		reset()
		try! tampered.write(to: staged)
		result = await importPackage(staged, expectedSHA256: nil)
		check(result.error == nil && Zip.extractedDigests == [sha256(tampered)],
		      "imports without a signed digest are unchanged")

		// Every extraction that ran with a digest matched it: checked per case above.
		print("Summary: \(passes) checks passed, \(failures) failures")
		if failures == 0 {
			print("SUCCESS: importer integrity checks passed")
		} else {
			print("FAILED: \(failures) check(s) failed")
			exit(1)
		}
	}
}

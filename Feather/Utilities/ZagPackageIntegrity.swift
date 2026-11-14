import Foundation
import CryptoKit

/// SHA-256 verification of a package file against a signed digest.
///
/// The importer calls this on its own private working copy, the exact file
/// it then extracts, so the verified bytes are the imported bytes.
enum ZagPackageIntegrity {
	enum Failure: Error, LocalizedError {
		case checksumMismatch

		var errorDescription: String? {
			"The package does not match its signed SHA-256."
		}
	}

	/// Streams the file in 1 MiB chunks so large IPAs are not held in memory.
	static func sha256(of url: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher = SHA256()
		while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	static func verify(_ url: URL, expectedSHA256: String) throws {
		guard try sha256(of: url).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
			throw Failure.checksumMismatch
		}
	}
}

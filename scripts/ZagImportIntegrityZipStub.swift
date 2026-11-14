import Foundation
import CryptoKit

// Stand-in for the Zip package, built as a module named Zip so the real
// AppFileHandler.swift compiles unchanged (scripts/test-zag-import-integrity.sh).
// unzipFile records the SHA-256 of the exact file it is asked to extract and
// writes a minimal Payload/Harness.app in its place.
public enum Zip {
	/// SHA-256 of every archive handed to unzipFile, in call order.
	public static var extractedDigests: [String] = []
	/// Runs inside unzipFile, before the archive is read.
	public static var beforeExtracting: ((URL) -> Void)?

	public static func addCustomFileExtension(_ fileExtension: String) {}

	public static func unzipFile(
		_ zipFilePath: URL,
		destination: URL,
		overwrite: Bool,
		password: String?,
		progress: ((Double) -> Void)? = nil
	) throws {
		beforeExtracting?(zipFilePath)
		let data = try Data(contentsOf: zipFilePath)
		extractedDigests.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
		let app = destination.appendingPathComponent("Payload/Harness.app", isDirectory: true)
		try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let info: [String: String] = ["CFBundleIdentifier": "app.zagstore.ios", "CFBundleShortVersionString": "1.0.1"]
		try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
			.write(to: app.appendingPathComponent("Info.plist"))
		progress?(1)
	}
}

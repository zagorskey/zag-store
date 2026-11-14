import Foundation
import UIKit
import CoreData
import CryptoKit
import IDeviceSwift

// Minimal stand-ins for the app types ZagSelfUpdateCoordinator.swift depends
// on, so the real coordinator source compiles into the integrity harness
// (scripts/test-zag-self-update-integrity.sh). Only the importer boundary is
// modelled faithfully: FR.handlePackageFile records the SHA-256 of the exact
// bytes it is handed before "importing" them.

protocol AppInfoPresentable: AnyObject {
	var uuid: String? { get }
}

@objc(Imported)
final class Imported: NSManagedObject, AppInfoPresentable {
	@NSManaged var uuid: String?
	@NSManaged var identifier: String?
	@NSManaged var version: String?
}

@objc(Signed)
final class Signed: NSManagedObject, AppInfoPresentable {
	@NSManaged var uuid: String?
	@NSManaged var identifier: String?
	@NSManaged var version: String?
}

/// In-memory Core Data store with the two entities the coordinator fetches.
final class Storage {
	static let shared = Storage()
	let context: NSManagedObjectContext
	let appsDirectory: URL

	private init() {
		func entity(_ name: String, _ type: AnyClass) -> NSEntityDescription {
			let description = NSEntityDescription()
			description.name = name
			description.managedObjectClassName = NSStringFromClass(type)
			description.properties = ["uuid", "identifier", "version"].map {
				let attribute = NSAttributeDescription()
				attribute.name = $0
				attribute.attributeType = .stringAttributeType
				attribute.isOptional = true
				return attribute
			}
			return description
		}
		let model = NSManagedObjectModel()
		model.entities = [entity("Imported", Imported.self), entity("Signed", Signed.self)]
		let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
		_ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
		context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
		context.persistentStoreCoordinator = coordinator
		appsDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("IntegrityHarnessApps", isDirectory: true)
	}

	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return appsDirectory.appendingPathComponent(uuid, isDirectory: true)
	}

	/// Creates a record and an app directory whose Info.plist carries `identity`.
	@discardableResult
	func insert<T: NSManagedObject & AppInfoPresentable>(
		_ type: T.Type, identity: [String: String]
	) throws -> T {
		let object = T(context: context)
		let uuid = UUID().uuidString
		object.setValue(uuid, forKey: "uuid")
		object.setValue(identity["CFBundleIdentifier"], forKey: "identifier")
		object.setValue(identity["CFBundleShortVersionString"], forKey: "version")
		let directory = getAppDirectory(for: object)!
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let plist = try PropertyListSerialization.data(fromPropertyList: identity, format: .xml, options: 0)
		try plist.write(to: directory.appendingPathComponent("Info.plist"))
		try context.save()
		return object
	}
}

enum FR {
	/// Number of import attempts the coordinator started.
	static var importAttempts = 0
	/// SHA-256 of the bytes each successful import extracted, in call order.
	static var importedDigests: [String] = []
	/// Info.plist identity the stub importer gives every imported app.
	static var importIdentity: [String: String] = [:]
	/// Thrown by signPackageFile so prepareSignedUpdate stops after import.
	struct StopAfterImport: Error {}

	/// Mirrors AppFileHandler: copy into a fresh working directory, verify
	/// that copy with the real ZagPackageIntegrity, and extract only the copy.
	static func handlePackageFile(
		_ ipa: URL,
		expectedSHA256: String? = nil,
		importedUUID: ((String) -> Void)? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task { @MainActor in
			importAttempts += 1
			let workDirectory = FileManager.default.temporaryDirectory
				.appendingPathComponent("FeatherImport_\(UUID().uuidString)", isDirectory: true)
			defer { try? FileManager.default.removeItem(at: workDirectory) }
			do {
				try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
				let copy = workDirectory.appendingPathComponent(ipa.lastPathComponent)
				try FileManager.default.copyItem(at: ipa, to: copy)
				if let expectedSHA256 {
					try ZagPackageIntegrity.verify(copy, expectedSHA256: expectedSHA256)
				}
				let data = try Data(contentsOf: copy)
				importedDigests.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
				let imported = try Storage.shared.insert(Imported.self, identity: importIdentity)
				importedUUID?(imported.uuid!)
				completion(nil)
			} catch {
				completion(error)
			}
		}
	}

	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		signedUUID: ((String) -> Void)? = nil,
		preserveProfileKeychainGroups: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		completion(StopAfterImport())
	}
}

struct Options {
	var ppqProtection = false
	var appIdentifier: String?
	var appEntitlementsFile: URL?
}

final class OptionsManager {
	static let shared = OptionsManager()
	var options = Options()
}

final class CertificatePair {}

struct Certificate {
	var TeamIdentifier: [String]
	var ExpirationDate: Date
	var Entitlements: [String: AnyCodable]?
}

/// Reads no profile: every provisioning check fails closed in the harness.
final class CertificateReader {
	let decoded: Certificate? = nil
	init(_ url: URL?) {}
}

final class ZagRPPairingCore {
	static let shared = ZagRPPairingCore()
	var pairingFileExists = false
	var isGate4Running = false
	var gate4AttemptEvents: [ZagGate4Event] = []

	struct NotAvailable: Error {}

	func installGate4IPA(
		at url: URL, deviceIP: String,
		completion: @escaping (Result<Void, Error>) -> Void
	) throws {
		throw NotAvailable()
	}
}

final class ArchiveHandler {
	struct NotAvailable: Error {}
	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {}
	func move() async throws { throw NotAvailable() }
	func archive() async throws -> URL { throw NotAvailable() }
}

import Foundation
import Combine
import CryptoKit
import CoreData
import IDeviceSwift

/// Self-update preparation and launch reconciliation.
/// Installation is intentionally not invoked until in-place RPPairing replacement
/// has been validated on a test device.
@MainActor
final class ZagSelfUpdateCoordinator: ObservableObject {
    static let shared = ZagSelfUpdateCoordinator()

    struct Release: Decodable {
        let version: String
        let build: String
        let bundleIdentifier: String
        let ipaURL: URL
        let sha256: String
        let minimumIOSVersion: String?
        let releaseNotes: String?
    }

    struct PendingInstallation: Codable {
        let version: String
        let build: String
        let bundleIdentifier: String
        let startedAt: Date
    }

    enum UpdateError: LocalizedError {
        case invalidRelease
        case incompatibleBundleIdentifier
        case insecureDownload
        case checksumMismatch
        case noUpdateAvailable
        case signedIdentityMismatch
        case pairingUnavailable
        case installationAlreadyRunning
        case unsupportedIOSVersion
        case incompatibleSigningTeam

        var errorDescription: String? {
            switch self {
            case .invalidRelease: return "The release metadata is incomplete or invalid."
            case .incompatibleBundleIdentifier: return "The update does not match this Zag Store installation."
            case .insecureDownload: return "Zag Store updates require HTTPS downloads."
            case .checksumMismatch: return "The downloaded IPA failed its SHA-256 verification."
            case .noUpdateAvailable: return "This Zag Store version is already up to date."
            case .signedIdentityMismatch: return "The signed update does not match the current Zag Store identity and version."
            case .pairingUnavailable: return "RPPairing must be configured before installing this update."
            case .installationAlreadyRunning: return "Another RPPairing installation is already running."
            case .unsupportedIOSVersion: return "This release requires a newer version of iOS."
            case .incompatibleSigningTeam: return "The update is signed by a different team. In-place replacement may not preserve app data."
            }
        }
    }

    @Published private(set) var preparedIPA: URL?
    @Published private(set) var availableRelease: Release?
    @Published private(set) var lastVerifiedInstallation: PendingInstallation?
    @Published private(set) var pendingInstallation: PendingInstallation?

    private let pendingKey = "zagStore.selfUpdate.pending"
    private let completedKey = "zagStore.selfUpdate.completed"

    private init() {
        pendingInstallation = Self.read(PendingInstallation.self, key: pendingKey)
        lastVerifiedInstallation = Self.read(PendingInstallation.self, key: completedKey)
        reconcileOnLaunch()
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private var currentBundleID: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    func reconcileOnLaunch() {
        guard let pending = pendingInstallation else { return }
        guard pending.bundleIdentifier == currentBundleID,
              pending.version == currentVersion,
              pending.build == currentBuild else { return }
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: completedKey)
        }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        pendingInstallation = nil
        lastVerifiedInstallation = pending
    }

    func checkForUpdate(manifestURL: URL) async throws -> Release? {
        guard manifestURL.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureDownload
        }
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.invalidRelease
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.version.isEmpty, !release.build.isEmpty,
              release.bundleIdentifier == currentBundleID else {
            throw UpdateError.incompatibleBundleIdentifier
        }
        guard release.ipaURL.scheme?.lowercased() == "https",
              release.sha256.count == 64,
              release.sha256.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF".unicodeScalars.contains($0) }) else {
            throw UpdateError.invalidRelease
        }
        try validateMinimumIOSVersion(for: release)
        let installed = currentVersion.compare(release.version, options: .numeric)
        let buildComparison = currentBuild.compare(release.build, options: .numeric)
        let newer = installed == .orderedAscending ||
            (installed == .orderedSame && buildComparison == .orderedAscending)
        availableRelease = newer ? release : nil
        return availableRelease
    }

    private func validateMinimumIOSVersion(for release: Release) throws {
        guard let minimum = release.minimumIOSVersion else { return }
        let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isNumber }) }),
              let major = Int(parts[0]) else {
            throw UpdateError.invalidRelease
        }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch else { throw UpdateError.invalidRelease }
        let required = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else {
            throw UpdateError.unsupportedIOSVersion
        }
    }

    func prepare(_ release: Release) async throws -> URL {
        guard release.bundleIdentifier == currentBundleID else {
            throw UpdateError.incompatibleBundleIdentifier
        }
        try validateMinimumIOSVersion(for: release)
        guard release.ipaURL.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureDownload
        }
        let (temporary, response) = try await URLSession.shared.download(from: release.ipaURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.invalidRelease
        }
        let data = try Data(contentsOf: temporary)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZagStore/SelfUpdate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("verified-release.ipa")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        preparedIPA = destination
        return destination
    }

    /// Call immediately before handing a signed, identity-validated IPA to
    /// the device installer. A callback from the old process is not required.
    func recordInstallationHandoff(for release: Release) throws {
        guard release.bundleIdentifier == currentBundleID else {
            throw UpdateError.incompatibleBundleIdentifier
        }
        let pending = PendingInstallation(
            version: release.version,
            build: release.build,
            bundleIdentifier: release.bundleIdentifier,
            startedAt: Date()
        )
        let data = try JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: pendingKey)
        pendingInstallation = pending
    }

    /// Import a checksum-verified IPA through the same handler used by
    /// repository downloads. Never download the IPA again after verification.
    func importPreparedRelease(_ release: Release) async throws -> Imported {
        guard release.bundleIdentifier == currentBundleID,
              let ipa = preparedIPA,
              FileManager.default.fileExists(atPath: ipa.path) else {
            throw UpdateError.invalidRelease
        }
        let uuid: String = try await withCheckedThrowingContinuation { continuation in
            var importedUUID: String?
            FR.handlePackageFile(
                ipa,
                importedUUID: { importedUUID = $0 },
                completion: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let uuid = importedUUID {
                        continuation.resume(returning: uuid)
                    } else {
                        continuation.resume(throwing: UpdateError.invalidRelease)
                    }
                }
            )
        }
        let request = NSFetchRequest<Imported>(entityName: "Imported")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        guard let imported = try Storage.shared.context.fetch(request).first,
              imported.identifier == currentBundleID,
              imported.version == release.version else {
            throw UpdateError.incompatibleBundleIdentifier
        }
        return imported
    }

    /// Prepare a release for a separate, explicitly confirmed installation.
    /// This method does not install or replace the running app.
    func prepareSignedUpdate(
        _ release: Release,
        certificate: CertificatePair
    ) async throws -> Signed {
        _ = try await prepare(release)
        let imported = try await importPreparedRelease(release)
        return try await signImportedRelease(imported, release: release, certificate: certificate)
    }

    /// Signs an already imported release without changing Zag Store's bundle ID.
    /// This prepares a candidate only; it never installs it automatically.
    func signImportedRelease(
        _ imported: Imported,
        release: Release,
        certificate: CertificatePair
    ) async throws -> Signed {
        try validateMinimumIOSVersion(for: release)
        guard release.bundleIdentifier == currentBundleID,
              imported.identifier == currentBundleID,
              imported.version == release.version else {
            throw UpdateError.incompatibleBundleIdentifier
        }

        var options = OptionsManager.shared.options
        // Do not apply the normal repository app's PPQ suffix or identifier map.
        options.ppqProtection = false
        options.appIdentifier = currentBundleID

        let signedUUID: String = try await withCheckedThrowingContinuation { continuation in
            var resultingUUID: String?
            FR.signPackageFile(
                imported,
                using: options,
                icon: nil,
                certificate: certificate,
                signedUUID: { resultingUUID = $0 }
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let uuid = resultingUUID {
                    continuation.resume(returning: uuid)
                } else {
                    continuation.resume(throwing: UpdateError.signedIdentityMismatch)
                }
            }
        }

        let request = NSFetchRequest<Signed>(entityName: "Signed")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "uuid == %@", signedUUID)
        guard let signed = try Storage.shared.context.fetch(request).first,
              signed.identifier == currentBundleID,
              signed.version == release.version else {
            throw UpdateError.signedIdentityMismatch
        }
        try validateSignedApp(signed, release: release)
        return signed
    }

    /// Check the signed app on disk, not just its Core Data metadata.
    /// Reject a different application identifier or build before handoff.
    func validateSignedApp(_ signed: Signed, release: Release) throws {
        guard release.bundleIdentifier == currentBundleID,
              let appURL = Storage.shared.getAppDirectory(for: signed),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              identifier == currentBundleID,
              version == release.version,
              build == release.build else {
            throw UpdateError.signedIdentityMismatch
        }
        try validateProvisioningTeam(at: appURL)
    }

    /// Compare embedded provisioning Team IDs before attempting replacement.
    /// A missing or unreadable profile fails closed.
    private func validateProvisioningTeam(at appURL: URL) throws {
        let installedProfile = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        let replacementProfile = appURL.appendingPathComponent("embedded.mobileprovision")
        guard let installed = CertificateReader(installedProfile).decoded,
              let replacement = CertificateReader(replacementProfile).decoded,
              let currentTeam = installed.TeamIdentifier.first,
              let nextTeam = replacement.TeamIdentifier.first,
              !currentTeam.isEmpty, currentTeam == nextTeam,
              replacement.ExpirationDate > Date() else {
            throw UpdateError.incompatibleSigningTeam
        }
    }

    /// Controlled test entry point. The caller must explicitly confirm the
    /// self-replacement experiment and supply a signed IPA already imported
    /// into Zag Store. This does not silently update the running application.
    ///
    /// The archive is prepared before recording the handoff so an archive
    /// failure never leaves a false pending installation.
    func installVerifiedSignedUpdate(
        _ signed: Signed,
        release: Release,
        userConfirmedSelfReplacement: Bool
    ) async throws {
        guard userConfirmedSelfReplacement else { throw UpdateError.invalidRelease }
        try validateMinimumIOSVersion(for: release)
        guard release.bundleIdentifier == currentBundleID,
              signed.identifier == currentBundleID,
              signed.version == release.version else {
            throw UpdateError.signedIdentityMismatch
        }
        try validateSignedApp(signed, release: release)
        let core = ZagRPPairingCore.shared
        guard core.pairingFileExists else { throw UpdateError.pairingUnavailable }
        guard !core.isGate4Running else { throw UpdateError.installationAlreadyRunning }

        let status = InstallerStatusViewModel(isIdevice: false)
        let archive = ArchiveHandler(app: signed, viewModel: status)
        try await archive.move()
        let packageURL = try await archive.archive()

        try recordInstallationHandoff(for: release)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try core.installGate4IPA(at: packageURL, deviceIP: "10.7.0.1", completion: { result in
                        continuation.resume(with: result)
                    })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            // Only clear the pending handoff for a confirmed failure.
            // If the process was terminated during replacement, the
            // persisted record is reconciled on the next launch.
            clearFailedHandoff()
            throw error
        }
    }

    func clearFailedHandoff() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
        pendingInstallation = nil
    }
}

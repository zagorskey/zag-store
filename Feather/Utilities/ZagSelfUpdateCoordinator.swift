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
        // Self-updates must not inherit a custom entitlement override.
        // Zsign will derive entitlements from the selected provisioning profile.
        options.appEntitlementsFile = nil

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

    /// Fail closed if the replacement profile cannot authorize the same
    /// application identity and keychain access as the running installation.
    private func validateProvisioningTeam(at appURL: URL) throws {
        let installedProfile = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        let replacementProfile = appURL.appendingPathComponent("embedded.mobileprovision")
        guard let installed = CertificateReader(installedProfile).decoded,
              let replacement = CertificateReader(replacementProfile).decoded,
              let currentTeam = installed.TeamIdentifier.first,
              let nextTeam = replacement.TeamIdentifier.first,
              !currentTeam.isEmpty, currentTeam == nextTeam,
              replacement.ExpirationDate > Date(),
              let currentEntitlements = installed.Entitlements,
              let nextEntitlements = replacement.Entitlements else {
            throw UpdateError.incompatibleSigningTeam
        }

        func string(_ entitlements: [String: AnyCodable], _ key: String) -> String? {
            entitlements[key]?.value as? String
        }
        func strings(_ entitlements: [String: AnyCodable], _ key: String) -> [String]? {
            entitlements[key]?.value as? [String]
        }

        let appIDKey = "application-identifier"
        let teamKey = "com.apple.developer.team-identifier"
        let expectedAppID = currentTeam + "." + currentBundleID

        // A wildcard provisioning App ID is not sufficient evidence for
        // safe self-replacement; require an explicit match on both profiles.
        guard string(currentEntitlements, appIDKey) == expectedAppID,
              string(nextEntitlements, appIDKey) == expectedAppID,
              string(currentEntitlements, teamKey) == currentTeam,
              string(nextEntitlements, teamKey) == currentTeam else {
            throw UpdateError.incompatibleSigningTeam
        }

        // Keychain access groups affect persistence across an update.
        // Require the replacement profile to retain every existing group.
        if let existingGroups = strings(currentEntitlements, "keychain-access-groups") {
            guard let replacementGroups = strings(nextEntitlements, "keychain-access-groups"),
                  Set(existingGroups).isSubset(of: Set(replacementGroups)) else {
                throw UpdateError.incompatibleSigningTeam
            }
        }

        // Do not allow a replacement to change the provisioning mode.
        if let existingDebug = currentEntitlements["get-task-allow"]?.value as? Bool {
            guard let replacementDebug = nextEntitlements["get-task-allow"]?.value as? Bool,
                  replacementDebug == existingDebug else {
                throw UpdateError.incompatibleSigningTeam
            }
        }
    }

    /// Diagnostic only: inspect the installed and candidate executable's
    /// embedded XML entitlements. Does not authorize installation.
    func inspectExecutableEntitlements(_ signed: Signed) throws -> [String: String] {
        guard let candidateURL = Storage.shared.getAppDirectory(for: signed),
              let currentExecutable = Bundle.main.executableURL,
              let candidateExecutableName = Bundle(url: candidateURL)?.object(
                forInfoDictionaryKey: "CFBundleExecutable"
              ) as? String else {
            throw UpdateError.signedIdentityMismatch
        }
        let candidateExecutable = candidateURL.appendingPathComponent(candidateExecutableName)
        let installed = try ZagMachOSignatureInspector.entitlements(at: currentExecutable)
        let replacement = try ZagMachOSignatureInspector.entitlements(at: candidateExecutable)
        let keys = [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "get-task-allow"
        ]
        var report: [String: String] = [:]
        for key in keys {
            guard let current = installed[key], let next = replacement[key] else {
                report[key] = "Missing in one or both signatures"
                continue
            }
            if let currentGroups = current as? [String],
               let nextGroups = next as? [String] {
                let missing = Set(currentGroups).subtracting(Set(nextGroups))
                if missing.isEmpty {
                    report[key] = "Exact compatible"
                } else if missing.allSatisfy({ group in
                    group.hasSuffix(".*") &&
                    nextGroups.contains(where: { candidate in
                        candidate.hasPrefix(String(group.dropLast())) &&
                        candidate.count > group.count - 1
                    })
                }) {
                    // This is a structural comparison only; it does not prove
                    // that existing keychain items remain accessible.
                    report[key] = "Wildcard-compatible (unverified)"
                } else {
                    report[key] = "Mismatch"
                }
            } else {
                report[key] = String(describing: current) == String(describing: next)
                    ? "Match" : "Mismatch"
            }
        }
        return report
    }

    /// Detailed read-only keychain diagnostics for the currently installed
    /// executable and a signed candidate. Never used to authorize installation.
    func inspectKeychainAccessGroups(_ signed: Signed) throws -> (installed: [String], candidate: [String]) {
        guard let appURL = Storage.shared.getAppDirectory(for: signed),
              let currentExecutable = Bundle.main.executableURL,
              let executableName = Bundle(url: appURL)?.object(
                forInfoDictionaryKey: "CFBundleExecutable"
              ) as? String else {
            throw UpdateError.signedIdentityMismatch
        }
        let installed = try ZagMachOSignatureInspector.entitlements(at: currentExecutable)
        let replacement = try ZagMachOSignatureInspector.entitlements(
            at: appURL.appendingPathComponent(executableName)
        )
        return (
            installed["keychain-access-groups"] as? [String] ?? [],
            replacement["keychain-access-groups"] as? [String] ?? []
        )
    }

    /// Compare embedded provisioning profiles with executable entitlements.
    /// Diagnostic only: profile authorization and actual keychain continuity
    /// require additional validation before self-replacement.
    func inspectKeychainProvisioning(_ signed: Signed) throws -> [String: String] {
        guard let appURL = Storage.shared.getAppDirectory(for: signed) else {
            throw UpdateError.signedIdentityMismatch
        }
        let installedURL = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        let candidateURL = appURL.appendingPathComponent("embedded.mobileprovision")
        guard let installed = CertificateReader(installedURL).decoded,
              let candidate = CertificateReader(candidateURL).decoded else {
            throw UpdateError.incompatibleSigningTeam
        }
        let actual = try inspectKeychainAccessGroups(signed)
        func profileGroups(_ certificate: Certificate) -> [String] {
            certificate.Entitlements?["keychain-access-groups"]?.value as? [String] ?? []
        }
        let currentProfile = profileGroups(installed)
        let nextProfile = profileGroups(candidate)
        func allows(_ profile: [String], group: String) -> Bool {
            profile.contains { permitted in
                permitted == group ||
                (permitted.hasSuffix(".*") &&
                 group.hasPrefix(String(permitted.dropLast())) &&
                 group.count > permitted.count - 1)
            }
        }
        let currentAuthorized = actual.installed.allSatisfy { allows(currentProfile, group: $0) }
        let nextAuthorized = actual.candidate.allSatisfy { allows(nextProfile, group: $0) }
        return [
            "Installed profile groups": currentProfile.joined(separator: "\\n"),
            "Candidate profile groups": nextProfile.joined(separator: "\\n"),
            "Installed entitlement/profile": currentAuthorized ? "Structurally compatible" : "Unverified or mismatch",
            "Candidate entitlement/profile": nextAuthorized ? "Structurally compatible" : "Unverified or mismatch",
            "Candidate profile expires": candidate.ExpirationDate.formatted(date: .abbreviated, time: .omitted),
            "Same provisioning team": installed.TeamIdentifier.first == candidate.TeamIdentifier.first ? "Yes" : "No"
        ]
    }

    /// Conservative, read-only self-update preflight. A passing structural
    /// check is not an installation authorization or signature verification.
    func inspectSelfUpdatePreflight(_ signed: Signed) -> [String: String] {
        var result: [String: String] = [:]
        let bundleID = currentBundleID
        guard let appURL = Storage.shared.getAppDirectory(for: signed),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) else {
            return ["Candidate bundle": "FAIL: missing signed app or Info.plist"]
        }
        let identifier = info["CFBundleIdentifier"] as? String
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        result["Bundle identifier"] = identifier == bundleID && signed.identifier == bundleID ? "PASS" : "FAIL"
        result["Candidate version/build"] = (version?.isEmpty == false && build?.isEmpty == false) ? "\(version ?? "") (\(build ?? ""))" : "FAIL"
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        result["Installed version/build"] = "\(currentVersion) (\(currentBuild))"
        result["RPPairing configured"] = ZagRPPairingCore.shared.pairingFileExists ? "YES" : "NO"
        result["Installer idle"] = !ZagRPPairingCore.shared.isGate4Running ? "YES" : "NO"
        do {
            let entitlements = try inspectExecutableEntitlements(signed)
            for key in ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow"] {
                result["Executable: " + key] = entitlements[key] ?? "MISSING"
            }
            result["Executable: keychain-access-groups"] = entitlements["keychain-access-groups"] ?? "MISSING"
            let profiles = try inspectKeychainProvisioning(signed)
            result["Provisioning team"] = profiles["Same provisioning team"] ?? "UNKNOWN"
            result["Installed entitlement/profile"] = profiles["Installed entitlement/profile"] ?? "UNKNOWN"
            result["Candidate entitlement/profile"] = profiles["Candidate entitlement/profile"] ?? "UNKNOWN"
        } catch {
            result["Signing inspection"] = "FAIL: " + error.localizedDescription
        }
        do {
            result["Keychain marker"] = try ZagSelfUpdateKeychainProbe.read() == nil ? "NOT CREATED" : "READABLE"
        } catch {
            result["Keychain marker"] = "FAIL: " + error.localizedDescription
        }
        result["Cryptographic signature verification"] = "NOT IMPLEMENTED"
        result["Installation authorization"] = "BLOCKED — diagnostic only"
        return result
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

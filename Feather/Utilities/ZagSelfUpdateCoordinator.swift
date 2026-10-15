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
        // Optional to preserve decoding of pending records created by older builds.
        let originatingBuild: String?
        // Hash of the signed candidate executable, not merely its version label.
        let expectedExecutableSHA256: String?
        // A candidate identical to the original executable cannot prove replacement.
        let originatingExecutableSHA256: String?
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

    private static func executableSHA256(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func reconcileOnLaunch() {
        guard let pending = pendingInstallation else { return }
        // A version/build match alone cannot prove the replacement occurred.
        // Legacy pending records without a candidate hash remain unconfirmed.
        guard pending.bundleIdentifier == currentBundleID,
              pending.version == currentVersion,
              pending.build == currentBuild,
              let expectedHash = pending.expectedExecutableSHA256,
              let executable = Bundle.main.executableURL,
              let actualHash = try? Self.executableSHA256(at: executable),
              actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame,
              let originalHash = pending.originatingExecutableSHA256,
              actualHash.caseInsensitiveCompare(originalHash) != .orderedSame else { return }
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
    func recordInstallationHandoff(for release: Release, signed: Signed) throws {
        guard release.bundleIdentifier == currentBundleID,
              let appURL = Storage.shared.getAppDirectory(for: signed),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let executableName = info["CFBundleExecutable"] as? String else {
            throw UpdateError.signedIdentityMismatch
        }
        let candidateHash = try Self.executableSHA256(at: appURL.appendingPathComponent(executableName))
        guard let currentExecutable = Bundle.main.executableURL else {
            throw UpdateError.signedIdentityMismatch
        }
        let originalHash = try Self.executableSHA256(at: currentExecutable)
        guard candidateHash.caseInsensitiveCompare(originalHash) != .orderedSame else {
            throw UpdateError.noUpdateAvailable
        }
        let pending = PendingInstallation(
            version: release.version,
            build: release.build,
            bundleIdentifier: release.bundleIdentifier,
            startedAt: Date(),
            originatingBuild: currentBuild,
            expectedExecutableSHA256: candidateHash,
            originatingExecutableSHA256: originalHash
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

    /// Local IPA diagnostic path. No manifest or installation is involved.
    /// The imported app's on-disk Info.plist supplies the identity to validate.
    func prepareLocalIPA(_ source: URL, certificate: CertificatePair) async throws -> Signed {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZagStore/SelfUpdate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("local-test-release.ipa")
        guard source.pathExtension.lowercased() == "ipa",
              source.standardizedFileURL != destination.standardizedFileURL else {
            throw UpdateError.invalidRelease
        }
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".ipa")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        let data = try Data(contentsOf: temporary)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        preparedIPA = destination

        // Import first, then validate the actual extracted bundle and build.
        let uuid: String = try await withCheckedThrowingContinuation { continuation in
            var importedUUID: String?
            FR.handlePackageFile(destination, importedUUID: { importedUUID = $0 }) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let importedUUID {
                    continuation.resume(returning: importedUUID)
                } else {
                    continuation.resume(throwing: UpdateError.invalidRelease)
                }
            }
        }
        let request = NSFetchRequest<Imported>(entityName: "Imported")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        guard let imported = try Storage.shared.context.fetch(request).first,
              let appURL = Storage.shared.getAppDirectory(for: imported),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              (bundleID == currentBundleID || bundleID == "thewonderofyou.Feather"),
              imported.identifier == bundleID,
              imported.version == version else {
            throw UpdateError.incompatibleBundleIdentifier
        }
        let release = Release(
            version: version, build: build, bundleIdentifier: currentBundleID,
            ipaURL: destination, sha256: digest,
            minimumIOSVersion: nil, releaseNotes: nil
        )
        return try await signImportedRelease(imported, release: release, certificate: certificate)
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
              (imported.identifier == currentBundleID || imported.identifier == "thewonderofyou.Feather"),
              imported.version == release.version else {
            throw UpdateError.incompatibleBundleIdentifier
        }

        var options = OptionsManager.shared.options
        // Do not apply the normal repository app's PPQ suffix or identifier map.
        options.ppqProtection = false
        options.appIdentifier = currentBundleID
        // Self-updates must not inherit a custom entitlement override.
        // Zsign will derive entitlements from the selected provisioning profile.
        // The resulting executable must then pass explicit identity checks;
        // profile compatibility alone is not installation authorization.
        options.appEntitlementsFile = nil

        let signedUUID: String = try await withCheckedThrowingContinuation { continuation in
            var resultingUUID: String?
            FR.signPackageFile(
                imported,
                using: options,
                icon: nil,
                certificate: certificate,
                signedUUID: { resultingUUID = $0 },
                preserveProfileKeychainGroups: true
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
        try validateExecutableIdentity(at: appURL)
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

    /// Require the signed executable to claim the same explicit identity as
    /// the running app. This is a structural preflight, not CMS trust proof.
    private func validateExecutableIdentity(at appURL: URL) throws {
        guard let currentExecutable = Bundle.main.executableURL,
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let executableName = info["CFBundleExecutable"] as? String else {
            throw UpdateError.signedIdentityMismatch
        }
        let installed = try ZagMachOSignatureInspector.entitlements(at: currentExecutable)
        let candidate = try ZagMachOSignatureInspector.entitlements(
            at: appURL.appendingPathComponent(executableName)
        )
        for key in ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow"] {
            guard let original = installed[key], let replacement = candidate[key],
                  String(describing: original) == String(describing: replacement) else {
                throw UpdateError.incompatibleSigningTeam
            }
        }
        guard let originalGroups = installed["keychain-access-groups"] as? [String],
              let replacementGroups = candidate["keychain-access-groups"] as? [String],
              let team = installed["com.apple.developer.team-identifier"] as? String,
              !team.isEmpty else {
            throw UpdateError.incompatibleSigningTeam
        }
        let candidateSet = Set(replacementGroups)
        let originalWildcard = team + ".*"
        let explicitAppGroup = team + "." + currentBundleID
        // The signer intentionally specializes the team's provisioning wildcard
        // to this app's concrete keychain group. Permit only that one structural
        // transition; every other previously signed group must remain present.
        // This does NOT establish access to pre-existing keychain items.
        let structurallyCompatible = originalGroups.allSatisfy { group in
            candidateSet.contains(group) ||
            (group == originalWildcard && candidateSet.contains(explicitAppGroup))
        }
        guard structurallyCompatible else {
            throw UpdateError.incompatibleSigningTeam
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
            "Installed executable groups": actual.installed.sorted().joined(separator: "\n"),
            "Candidate executable groups": actual.candidate.sorted().joined(separator: "\n"),
            "Executable groups identical": Set(actual.installed) == Set(actual.candidate) ? "YES" : "NO",
            "Installed profile groups": currentProfile.joined(separator: "\n"),
            "Candidate profile groups": nextProfile.joined(separator: "\n"),
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
        // An identical version/build cannot demonstrate that a self-update
        // replaced the installed application.
        if let version, let build, !version.isEmpty, !build.isEmpty {
            let candidateVersion = version.split(separator: ".").compactMap { Int($0) }
            let installedVersion = currentVersion.split(separator: ".").compactMap { Int($0) }
            let validVersions = candidateVersion.count == version.split(separator: ".").count &&
                installedVersion.count == currentVersion.split(separator: ".").count
            if validVersions {
                if candidateVersion.lexicographicallyPrecedes(installedVersion) {
                    result["Newer candidate"] = "NO — older version"
                } else if installedVersion.lexicographicallyPrecedes(candidateVersion) {
                    result["Newer candidate"] = "YES — newer version"
                } else if let candidateBuild = Int(build), let installedBuild = Int(currentBuild) {
                    result["Newer candidate"] = candidateBuild > installedBuild
                        ? "YES — newer build" : "NO — same or older build"
                } else {
                    result["Newer candidate"] = "UNVERIFIED — nonnumeric build"
                }
            } else {
                result["Newer candidate"] = "UNVERIFIED — nonnumeric version"
            }
        } else {
            result["Newer candidate"] = "NO — missing version or build"
        }
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
            let marker = try ZagSelfUpdateKeychainProbe.read()
            result["Keychain marker"] = marker == nil ? "NOT CREATED" : "READABLE"
            if marker != nil {
                let group = try ZagSelfUpdateKeychainProbe.markerAccessGroup()
                result["Marker access group"] = group ?? "UNAVAILABLE"
                let signedGroups = try inspectKeychainAccessGroups(signed).candidate
                result["Marker group in candidate executable"] = group.map {
                    signedGroups.contains($0) ? "YES" : "NO"
                } ?? "UNVERIFIED"
            }
        } catch {
            result["Keychain marker"] = "FAIL: " + error.localizedDescription
        }
        do {
            guard let executableName = info["CFBundleExecutable"] as? String else {
                throw UpdateError.signedIdentityMismatch
            }
            result["Code page SHA-256 integrity"] = try ZagMachOSignatureInspector.inspectCodePageHashes(
                at: appURL.appendingPathComponent(executableName)
            )
        } catch {
            result["Code page SHA-256 integrity"] = "UNVERIFIED — " + error.localizedDescription
        }
        // A valid-looking embedded provisioning profile and matching hashes do
        // not establish that iOS trusts the CMS code signature. Report each
        // separate check explicitly so diagnostics cannot be mistaken for an
        // installation authorization decision.
        do {
            try validateProvisioningTeam(at: appURL)
            result["Provisioning identity compatibility"] = "PASS — structural comparison only"
        } catch {
            result["Provisioning identity compatibility"] = "FAIL — " + error.localizedDescription
        }
        result["Cryptographic signature verification"] = "NOT IMPLEMENTED — CMS trust and signed resource sealing not verified"
        result["Installation authorization"] = "BLOCKED — diagnostic only; no self-replacement permitted"
        return result
    }

    /// Controlled test entry point. The caller must explicitly confirm the
    /// self-replacement experiment and supply a signed IPA already imported
    /// into Zag Store. This does not silently update the running application.
    ///
    /// The archive is prepared before recording the handoff so an archive
    /// failure never leaves a false pending installation.
    /// Assemble and verify the exact IPA intended for Gate4. This is safe to
    /// call while installation authorization is locked: no installer is invoked.
    func stageSignedSelfUpdate(_ signed: Signed, release: Release) async throws -> URL {
        try validateMinimumIOSVersion(for: release)
        guard release.bundleIdentifier == currentBundleID,
              signed.identifier == currentBundleID,
              signed.version == release.version else {
            throw UpdateError.signedIdentityMismatch
        }
        try validateSignedApp(signed, release: release)
        guard let marker = try ZagSelfUpdateKeychainProbe.read(),
              !marker.isEmpty,
              let markerGroup = try ZagSelfUpdateKeychainProbe.markerAccessGroup(),
              try inspectKeychainAccessGroups(signed).candidate.contains(markerGroup) else {
            throw UpdateError.signedIdentityMismatch
        }
        let core = ZagRPPairingCore.shared
        guard core.pairingFileExists else { throw UpdateError.pairingUnavailable }
        guard !core.isGate4Running else { throw UpdateError.installationAlreadyRunning }

        let status = InstallerStatusViewModel(isIdevice: false)
        let archive = ArchiveHandler(app: signed, viewModel: status)
        try await archive.move()
        let packageURL = try await archive.archive()
        guard FileManager.default.fileExists(atPath: packageURL.path),
              (try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw UpdateError.invalidRelease
        }
        return packageURL
    }

    /// Installer callbacks are not proof of replacement. A later launch
    /// must verify the expected executable before reporting success.
    private func submitStagedUpdateToGate4(_ packageURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try ZagRPPairingCore.shared.installGate4IPA(
                    at: packageURL,
                    deviceIP: "10.7.0.1",
                    completion: { result in continuation.resume(with: result) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Record a pending handoff only after staging and identity checks pass.
    /// This helper does not contact the installation service.
    private func persistStagedHandoff(for release: Release, signed: Signed) throws {
        try validateSignedApp(signed, release: release)
        try recordInstallationHandoff(for: release, signed: signed)
    }

    /// Stages an IPA and records the expected executable before installation.
    /// Reserved for a future authorized installation path; never called by UI.
    private func prepareInstallationHandoff(
        _ signed: Signed,
        release: Release
    ) async throws -> URL {
        let packageURL = try await stageSignedSelfUpdate(signed, release: release)
        try persistStagedHandoff(for: release, signed: signed)
        return packageURL
    }

    /// Pending state is intentionally retained after an ambiguous installer
    /// callback. The next launch can then verify whether replacement occurred.
    private func performPreparedHandoff(
        _ signed: Signed,
        release: Release
    ) async throws {
        let packageURL = try await prepareInstallationHandoff(signed, release: release)
        try await submitStagedUpdateToGate4(packageURL)
    }

    /// Explicitly confirmed upgrade-only handoff. Never called during preparation.
    /// The original process may terminate before Gate4 returns a callback.
    func installVerifiedSignedUpdate(
        _ signed: Signed,
        release: Release,
        userConfirmedSelfReplacement: Bool
    ) async throws {
        guard userConfirmedSelfReplacement else { throw UpdateError.invalidRelease }
        guard pendingInstallation == nil else { throw UpdateError.installationAlreadyRunning }
        guard signed.identifier == currentBundleID else { throw UpdateError.incompatibleBundleIdentifier }
        try await performPreparedHandoff(signed, release: release)
    }

    /// Build release metadata from the selected signed candidate, not from
    /// whichever Zag Store record happens to be first in the database.
    func installSelectedLocalCandidate(_ signed: Signed, userConfirmedSelfReplacement: Bool) async throws {
        guard userConfirmedSelfReplacement else { throw UpdateError.invalidRelease }
        guard let ipa = preparedIPA, FileManager.default.fileExists(atPath: ipa.path),
              let appURL = Storage.shared.getAppDirectory(for: signed),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              identifier == currentBundleID else {
            throw UpdateError.signedIdentityMismatch
        }
        let data = try Data(contentsOf: ipa)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let release = Release(version: version, build: build, bundleIdentifier: identifier,
                              ipaURL: ipa, sha256: digest,
                              minimumIOSVersion: nil, releaseNotes: nil)
        try await installVerifiedSignedUpdate(signed, release: release,
                                              userConfirmedSelfReplacement: true)
    }

    /// Read-only assessment of the prepared candidate and Gate4 prerequisites.
    /// This deliberately does not authorize or invoke self-installation.
    func inspectInstallationHandoffReadiness() -> [String] {
        var findings: [String] = []
        let request = NSFetchRequest<Signed>(entityName: "Signed")
        request.predicate = NSPredicate(format: "identifier == %@", currentBundleID)
        do {
            let candidates = try Storage.shared.context.fetch(request)
            findings.append("Signed candidates: " + String(candidates.count))
            if candidates.count == 1, let candidate = candidates.first,
               let appURL = Storage.shared.getAppDirectory(for: candidate),
               let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
               let executableName = info["CFBundleExecutable"] as? String,
               let currentExecutable = Bundle.main.executableURL {
                let nextExecutable = appURL.appendingPathComponent(executableName)
                let nextHash = try Self.executableSHA256(at: nextExecutable)
                let currentHash = try Self.executableSHA256(at: currentExecutable)
                findings.append("Candidate executable differs: " + (nextHash == currentHash ? "NO" : "YES"))
                findings.append("Candidate version: " + (info["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info["CFBundleVersion"] as? String ?? "?") + ")")
            } else {
                findings.append("Candidate selection or executable: NOT READY")
            }
        } catch {
            findings.append("Candidate inspection: " + error.localizedDescription)
        }
        let core = ZagRPPairingCore.shared
        findings.append("Pairing file: " + (core.pairingFileExists ? "AVAILABLE" : "MISSING"))
        findings.append("Gate4 busy: " + (core.isGate4Running ? "YES" : "NO"))
        findings.append("Installation authorization: BLOCKED — not verified")
        return findings
    }

    func clearFailedHandoff() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
        pendingInstallation = nil
    }
}

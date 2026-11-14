import Foundation
import UIKit
import Combine
import CryptoKit
import CoreData
import IDeviceSwift
import Network

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

    // Stable is the default. Existing "off" preferences migrate without changing
    // the user's selection; it means prerelease updates are disabled.
    enum UpdateChannel: String, CaseIterable {
        case stable, beta, nightly

        static let preferenceKey = "ZagStore.updatePreferences.betaChannel.placeholder"

        static var selected: Self {
            let stored = UserDefaults.standard.string(forKey: preferenceKey) ?? "off"
            return Self(rawValue: stored) ?? .stable
        }

        var manifestURL: URL {
            URL(string: "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/\(rawValue).json")!
        }

        /// Reserved for authenticated v2 channel metadata. Not enabled by
        /// normal update checks until signed manifests are published.
        var authenticatedV2ManifestURL: URL? {
            switch self {
            case .stable: return nil
            case .beta, .nightly:
                return URL(string: "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/\(rawValue).json")
            }
        }
    }

    private let betaV2RollbackStore = ZagUpdateRollbackStore(
        service: "app.zagstore.ios.update-metadata-v2.production-beta"
    )

    func checkForSelectedChannel() async throws -> Release? {
        let channel = UpdateChannel.selected
        if channel == .beta, let endpoint = channel.authenticatedV2ManifestURL {
            return try await checkAuthenticatedV2Channel(
                endpoint: endpoint, channel: channel, rollbackStore: betaV2RollbackStore
            )
        }
        return try await checkForUpdate(manifestURL: channel.manifestURL)
    }

    /// Authenticated discovery for a future v2 channel cutover. This method
    /// does not alter the current v1 discovery path or authorize installation.
    func checkAuthenticatedV2Channel(
        endpoint: URL,
        channel: UpdateChannel,
        rollbackStore: ZagUpdateRollbackStore
    ) async throws -> Release? {
        let generation = checkGeneration
        let payload = try await ZagUpdateV2Discovery.fetchVerified(
            from: endpoint,
            channel: channel.rawValue,
            trustedKeys: ZagUpdateTrustStore.productionKeys,
            store: rollbackStore
        )
        guard let ipaURL = URL(string: payload.ipaURL) else {
            throw UpdateError.invalidRelease
        }
        let release = Release(
            version: payload.version,
            build: payload.build,
            bundleIdentifier: canonicalReleaseBundleID,
            ipaURL: ipaURL,
            sha256: payload.sha256,
            minimumIOSVersion: payload.minimumIOSVersion,
            releaseNotes: payload.releaseNotes
        )
        let versionOrder = currentVersion.compare(release.version, options: .numeric)
        let buildOrder = currentBuild.compare(release.build, options: .numeric)
        let newer = versionOrder == .orderedAscending ||
            (versionOrder == .orderedSame && buildOrder == .orderedAscending)
        let result: Release? = newer ? release : nil
        guard generation == checkGeneration, channel == UpdateChannel.selected else { return nil }
        availableRelease = result
        return result
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
        case channelNotPublished
        case keychainContinuityMismatch
        case previousAttemptUnverified
        case incompatibleDeviceFamily

        var errorDescription: String? {
            switch self {
            case .incompatibleDeviceFamily: return "This update is built for a different device type (iPhone or iPad) and would not run natively on this device."
            case .previousAttemptUnverified: return "A previous update attempt has not been confirmed yet. Reopen Zag Store to verify it, or clear it in Zag Store Update and try again."
            case .keychainContinuityMismatch: return "The signed update would lose access to Zag Store's saved keychain data. Sign it with a certificate from the same team as the installed app."
            case .invalidRelease: return "The release metadata is incomplete or invalid."
            case .channelNotPublished: return "No release manifest has been published for this channel yet."
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

    // Discovery only: never download, sign, or install without user action.
    @Published private(set) var automaticCheckStatus = "Waiting for update check"
    static let automaticChecksKey = "ZagStore.updatePreferences.automaticChecks.v1"
    static let automaticWiFiDownloadKey = "ZagStore.updatePreferences.wifiDownload.v1"
    @Published private(set) var automaticDownloadStatus = "Not downloaded"
    private var wifiMonitor: NWPathMonitor?
    private var wifiAvailable = false
    private var downloadInProgress = false
    private var downloadedReleaseIdentity: String?

    private func releaseIdentity(_ release: Release) -> String {
        [release.version, release.build, release.sha256.lowercased()].joined(separator: "|")
    }

    private func downloadOnWiFiIfEnabled(_ release: Release) async {
        guard UserDefaults.standard.bool(forKey: Self.automaticWiFiDownloadKey),
              wifiAvailable, !downloadInProgress, pendingInstallation == nil else { return }
        let identity = releaseIdentity(release)
        guard downloadedReleaseIdentity != identity else { return }
        downloadInProgress = true
        automaticDownloadStatus = "Downloading on Wi-Fi…"
        defer { downloadInProgress = false }
        do {
            let configuration = URLSessionConfiguration.default
            configuration.allowsCellularAccess = false
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let data = try await downloadVerifiedIPA(release, session: session)
            guard wifiAvailable else { throw UpdateError.invalidRelease }
            preparedIPA = try stageVerifiedIPA(data)
            downloadedReleaseIdentity = identity
            automaticDownloadStatus = "Downloaded and SHA-256 verified — ready to sign"
        } catch {
            automaticDownloadStatus = "Wi-Fi download failed: " + error.localizedDescription
        }
    }
    private var lastAutomaticCheck: Date?
    private var lastCheckedChannel: UpdateChannel?
    private var checkGeneration = 0
    private var automaticCheckInProgress = false
    private var foregroundObserver: NSObjectProtocol?
    private let automaticCheckInterval: TimeInterval = 60 * 60 * 6

    func checkAutomatically(force: Bool = false) async {
        guard UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true else {
            automaticCheckStatus = "Automatic update checks off"
            return
        }
        guard !automaticCheckInProgress else { return }
        let channel = UpdateChannel.selected
        if !force, lastCheckedChannel == channel, let lastAutomaticCheck,
           Date().timeIntervalSince(lastAutomaticCheck) < automaticCheckInterval { return }
        automaticCheckInProgress = true
        lastCheckedChannel = channel
        lastAutomaticCheck = Date()
        let generation = checkGeneration
        automaticCheckStatus = "Checking for updates…"
        defer { automaticCheckInProgress = false }
        do {
            let release: Release?
            if channel == .beta, let endpoint = channel.authenticatedV2ManifestURL {
                release = try await checkAuthenticatedV2Channel(
                    endpoint: endpoint, channel: channel, rollbackStore: betaV2RollbackStore
                )
            } else {
                release = try await fetchUpdate(manifestURL: channel.manifestURL)
            }
            guard generation == checkGeneration, channel == UpdateChannel.selected else { return }
            availableRelease = release
            if let release {
                automaticCheckStatus = "Update available: \(release.version) (Build \(release.build)) — \(channel.rawValue.capitalized)"
                await downloadOnWiFiIfEnabled(release)
            } else {
                automaticCheckStatus = "Up to date — \(channel.rawValue.capitalized)"
            }
        } catch {
            guard generation == checkGeneration, channel == UpdateChannel.selected else { return }
            availableRelease = nil
            if case UpdateError.channelNotPublished = error {
                automaticCheckStatus = "No release published — \(channel.rawValue.capitalized)"
            } else {
                automaticCheckStatus = "Update check failed: " + error.localizedDescription
            }
        }
    }

    func preferencesChanged() {
        checkGeneration += 1
        availableRelease = nil
        preparedIPA = nil
        downloadedReleaseIdentity = nil
        automaticDownloadStatus = "Not downloaded"
        lastAutomaticCheck = nil
        lastCheckedChannel = nil
        automaticCheckStatus = "Waiting for update check"
        if UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true {
            Task { @MainActor in
                // Let an in-flight check finish before forcing the new channel.
                while automaticCheckInProgress {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await checkAutomatically(force: true)
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
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifiMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasAvailable = self.wifiAvailable
                self.wifiAvailable = path.status == .satisfied
                if self.wifiAvailable && !wasAvailable, let release = self.availableRelease {
                    await self.downloadOnWiFiIfEnabled(release)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.zagstore.selfupdate.wifi"))
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.checkAutomatically() }
        }
        Task { @MainActor in await checkAutomatically() }
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
        let generation = checkGeneration
        let release = try await fetchUpdate(manifestURL: manifestURL)
        guard generation == checkGeneration,
              manifestURL == UpdateChannel.selected.manifestURL else { return nil }
        availableRelease = release
        return release
    }

    private let canonicalReleaseBundleID = "app.zagstore.ios"

    // Legacy channel manifests remain valid until their canonical replacements ship.
    private func isSupportedReleaseIdentity(_ id: String) -> Bool {
        id == canonicalReleaseBundleID || id == currentBundleID
    }

    private func fetchUpdate(manifestURL: URL) async throws -> Release? {
        guard manifestURL.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureDownload
        }
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidRelease
        }
        if http.statusCode == 404 { throw UpdateError.channelNotPublished }
        guard http.statusCode == 200 else { throw UpdateError.invalidRelease }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.version.isEmpty, !release.build.isEmpty,
              isSupportedReleaseIdentity(release.bundleIdentifier) else {
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
        return newer ? release : nil
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
        guard isSupportedReleaseIdentity(release.bundleIdentifier) else {
            throw UpdateError.incompatibleBundleIdentifier
        }
        try validateMinimumIOSVersion(for: release)
        guard release.ipaURL.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureDownload
        }
        if downloadedReleaseIdentity == releaseIdentity(release),
           let cached = preparedIPA, FileManager.default.fileExists(atPath: cached.path),
           (try? ZagPackageIntegrity.verify(cached, expectedSHA256: release.sha256)) != nil {
            return cached
        }
        // Whatever was prepared before is stale now. Discard it first, so a
        // failed attempt can never leave an earlier file available to import.
        discardPreparedIPA()
        let destination = try stageVerifiedIPA(try await downloadVerifiedIPA(release, session: .shared))
        preparedIPA = destination
        return destination
    }

    /// Downloads the IPA into memory and checks it against the signed SHA-256.
    /// Nothing reaches disk unless it verifies, so a rejected or interrupted
    /// download leaves no file behind (a download task would leave its own
    /// temporary file when the connection drops).
    private func downloadVerifiedIPA(_ release: Release, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: release.ipaURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.invalidRelease
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }
        return data
    }

    /// Writes verified bytes to the single staging location.
    private func stageVerifiedIPA(_ data: Data) throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZagStore/SelfUpdate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("verified-release.ipa")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Call immediately before handing a signed, identity-validated IPA to
    /// the device installer. A callback from the old process is not required.
    func recordInstallationHandoff(for release: Release, signed: Signed) throws {
        guard isSupportedReleaseIdentity(release.bundleIdentifier),
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
            bundleIdentifier: currentBundleID,
            startedAt: Date(),
            originatingBuild: currentBuild,
            expectedExecutableSHA256: candidateHash,
            originatingExecutableSHA256: originalHash
        )
        let data = try JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: pendingKey)
        pendingInstallation = pending
    }

    /// Forget and delete the staged IPA. Pending-installation and recovery
    /// records are separate and deliberately untouched.
    private func discardPreparedIPA() {
        if let staged = preparedIPA {
            try? FileManager.default.removeItem(at: staged)
        }
        if downloadedReleaseIdentity != nil {
            automaticDownloadStatus = "Not downloaded"
        }
        preparedIPA = nil
        downloadedReleaseIdentity = nil
    }

    /// Import a checksum-verified IPA through the same handler used by
    /// repository downloads. Never download the IPA again after verification.
    /// The handler re-verifies the signed SHA-256 on its own working copy, the
    /// file it extracts, so a file changed after `prepare` is never imported.
    func importPreparedRelease(_ release: Release) async throws -> Imported {
        guard isSupportedReleaseIdentity(release.bundleIdentifier),
              let ipa = preparedIPA,
              FileManager.default.fileExists(atPath: ipa.path) else {
            throw UpdateError.invalidRelease
        }
        let uuid: String = try await withCheckedThrowingContinuation { continuation in
            var importedUUID: String?
            FR.handlePackageFile(
                ipa,
                expectedSHA256: release.sha256,
                importedUUID: { importedUUID = $0 },
                completion: { error in
                    if case ZagPackageIntegrity.Failure.checksumMismatch? = error {
                        continuation.resume(throwing: UpdateError.checksumMismatch)
                    } else if let error {
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
              let appURL = Storage.shared.getAppDirectory(for: imported),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let actualIdentifier = info["CFBundleIdentifier"] as? String,
              let actualVersion = info["CFBundleShortVersionString"] as? String,
              let actualBuild = info["CFBundleVersion"] as? String,
              actualIdentifier == release.bundleIdentifier,
              actualVersion == release.version,
              actualBuild == release.build,
              imported.identifier == actualIdentifier,
              imported.version == actualVersion else {
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

    /// Explicit, test-only authenticated v2 preparation. The caller supplies a
    /// separate test endpoint and an isolated rollback store. This does not
    /// modify channel preferences, availableRelease, or invoke installation.
    /// Do not call from automatic update checks or the live v1 updater.
    func prepareAuthenticatedV2TestCandidate(
        endpoint: URL,
        channel: String,
        rollbackStore: ZagUpdateRollbackStore,
        certificate: CertificatePair
    ) async throws -> (release: Release, signed: Signed) {
        let payload = try await ZagUpdateV2Discovery.fetchVerified(
            from: endpoint,
            channel: channel,
            trustedKeys: ZagUpdateTrustStore.productionKeys,
            store: rollbackStore
        )
        guard let ipaURL = URL(string: payload.ipaURL) else {
            throw UpdateError.invalidRelease
        }
        let release = Release(
            version: payload.version,
            build: payload.build,
            bundleIdentifier: canonicalReleaseBundleID,
            ipaURL: ipaURL,
            sha256: payload.sha256,
            minimumIOSVersion: payload.minimumIOSVersion,
            releaseNotes: payload.releaseNotes
        )
        // A signed manifest is not authorization to downgrade or reinstall.
        let versionOrder = currentVersion.compare(release.version, options: .numeric)
        let buildOrder = currentBuild.compare(release.build, options: .numeric)
        guard versionOrder == .orderedAscending ||
              (versionOrder == .orderedSame && buildOrder == .orderedAscending) else {
            throw UpdateError.noUpdateAvailable
        }
        let signed = try await prepareSignedUpdate(release, certificate: certificate)
        return (release, signed)
    }

    /// Signs an already imported release without changing Zag Store's bundle ID.
    /// This prepares a candidate only; it never installs it automatically.
    func signImportedRelease(
        _ imported: Imported,
        release: Release,
        certificate: CertificatePair
    ) async throws -> Signed {
        try validateMinimumIOSVersion(for: release)
        guard isSupportedReleaseIdentity(release.bundleIdentifier),
              imported.identifier == release.bundleIdentifier,
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
        guard isSupportedReleaseIdentity(release.bundleIdentifier),
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
        // An iPhone-only build would run in compatibility mode on an iPad, and
        // an iPad-only build cannot install on an iPhone.
        guard ZagDeviceFamilyPolicy.allowsReplacement(
            candidate: ZagDeviceFamilyPolicy.families(fromInfoPlistValue: info["UIDeviceFamily"]),
            installed: ZagDeviceFamilyPolicy.families(fromInfoPlistValue: Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily")),
            device: ZagDeviceFamilyPolicy.currentDevice()
        ) else {
            throw UpdateError.incompatibleDeviceFamily
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
        guard isSupportedReleaseIdentity(release.bundleIdentifier),
              signed.identifier == currentBundleID,
              signed.version == release.version else {
            throw UpdateError.signedIdentityMismatch
        }
        try validateSignedApp(signed, release: release)
        // The marker lets iOS report the keychain access group this running
        // app actually writes to. Provision it here so ordinary users are not
        // blocked; the candidate must still be entitled to that exact group.
        let marker = try ZagSelfUpdateKeychainProbe.createIfMissing()
        guard !marker.isEmpty,
              let markerGroup = try ZagSelfUpdateKeychainProbe.markerAccessGroup(),
              try inspectKeychainAccessGroups(signed).candidate.contains(markerGroup) else {
            throw UpdateError.keychainContinuityMismatch
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
    private func submitStagedUpdateToGate4(
        _ packageURL: URL,
        onStarted: () -> Void,
        onFinished: @escaping ([ZagGate4Event]) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try ZagRPPairingCore.shared.installGate4IPA(
                    at: packageURL,
                    deviceIP: "10.7.0.1",
                    completion: { result in
                        // Snapshot this attempt's callbacks at the moment it
                        // ended, before any later attempt can reset them.
                        onFinished(ZagRPPairingCore.shared.gate4AttemptEvents)
                        continuation.resume(with: result)
                    }
                )
                onStarted()
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
        var installerStarted = false
        var finishedEvents: [ZagGate4Event]?
        do {
            try await submitStagedUpdateToGate4(
                packageURL,
                onStarted: { installerStarted = true },
                onFinished: { finishedEvents = $0 }
            )
        } catch {
            // Release the record only if the callbacks prove the Upgrade
            // request was never sent, so the user can retry. Anything else
            // keeps it for launch verification. The rollback store is not
            // involved either way.
            let progress: ZagSelfUpdateRetryPolicy.InstallerProgress = installerStarted
                ? ZagSelfUpdateRetryPolicy.progress(afterEvents: finishedEvents)
                : .notStarted
            if ZagSelfUpdateRetryPolicy.mayReleasePendingRecord(after: progress) {
                clearFailedHandoff()
                ZagLogger.shared.warning("SelfUpdate", "Installer failed before the Upgrade request; pending record released for retry")
            } else {
                ZagLogger.shared.warning("SelfUpdate", "Installer result is ambiguous; pending record kept for launch verification")
            }
            throw error
        }
    }

    /// Explicitly confirmed upgrade-only handoff. Never called during preparation.
    /// The original process may terminate before Gate4 returns a callback.
    func installVerifiedSignedUpdate(
        _ signed: Signed,
        release: Release,
        userConfirmedSelfReplacement: Bool
    ) async throws {
        guard userConfirmedSelfReplacement else { throw UpdateError.invalidRelease }
        guard pendingInstallation == nil else { throw UpdateError.previousAttemptUnverified }
        guard signed.identifier == currentBundleID else { throw UpdateError.incompatibleBundleIdentifier }
        try await performPreparedHandoff(signed, release: release)
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

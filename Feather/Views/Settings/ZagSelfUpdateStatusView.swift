import SwiftUI
import UIKit
import CoreData
import CryptoKit
import AltSourceKit
import UniformTypeIdentifiers

/// Dedicated, non-destructive self-update status screen.
/// Installation remains disabled until signature authorization and recovery
/// are implemented and verified. Never route self-updates through Library.
struct ZagSelfUpdateStatusView: View {
    @ObservedObject private var coordinator = ZagSelfUpdateCoordinator.shared
    @ObservedObject private var gate4 = ZagRPPairingCore.shared

    // Automatic discovery is independent from installation.
    @AppStorage("ZagStore.updatePreferences.automaticChecks.v1")
    private var zagAutoCheckEnabled = true
    @AppStorage("ZagStore.updatePreferences.betaChannel.placeholder")
    private var zagBetaChannel = "off"

    // A verified replacement receives a one-time success celebration.
    // Never acknowledge the next build in advance.
    @AppStorage("zagStore.selfUpdate.acknowledgedReplacement.v1")
    private var acknowledgedReplacement = ""



    @State private var v2TestBusy = false
    @State private var v2TestStatus = "Not prepared"
    @State private var v2TestCandidate: String?

    private func prepareAuthenticatedBetaTest() {
        guard !v2TestBusy else { return }
        v2TestBusy = true
        v2TestCandidate = nil
        v2TestStatus = "Selecting signing certificate…"
        Task { @MainActor in
            defer { v2TestBusy = false }
            guard let certificate = await ZagCertificateSelection.chooseForSigning() else {
                v2TestStatus = "Cancelled — no signing certificate selected"
                return
            }
            v2TestStatus = "Authenticating Beta metadata and preparing signed candidate…"
            do {
                let endpoint = URL(string: "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2-test/beta-1.0.0-3.json")!
                // Separate from production rollback history; intentionally retained
                // between test attempts to exercise sequence continuity.
                let testStore = ZagUpdateRollbackStore(
                    service: "app.zagstore.ios.update-metadata-v2.test-beta-only"
                )
                let result = try await coordinator.prepareAuthenticatedV2TestCandidate(
                    endpoint: endpoint, channel: "beta",
                    rollbackStore: testStore, certificate: certificate
                )
                try coordinator.validateSignedApp(result.signed, release: result.release)
                v2TestCandidate = result.signed.uuid
                v2TestStatus = "PASS — authenticated and signed \(result.release.version) (Build \(result.release.build)). No installation performed."
            } catch {
                v2TestStatus = "FAIL — " + error.localizedDescription
            }
        }
    }

    @State private var report: [(key: String, value: String)] = []
    @State private var checkStatus = "Not checked"
    @State private var releaseCheckStatus = "Not checked"
    @State private var releaseCheckBusy = false
    @State private var releaseDownloadSize: String?
    @State private var releaseDownloadBusy = false
    @State private var markerStatus = "Not checked"

    private static var installedAppIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let names = primary["CFBundleIconFiles"] as? [String],
              let name = names.last else { return nil }
        return UIImage(named: name)
    }

    private func createMarker() {
        do {
            let existing = try ZagSelfUpdateKeychainProbe.read()
            let marker = try ZagSelfUpdateKeychainProbe.createIfMissing()
            markerStatus = (existing == nil ? "Created" : "Existing marker retained") + " (ending " + String(marker.suffix(8)) + ")"
        } catch {
            markerStatus = "FAIL — " + error.localizedDescription
        }
    }

    private func verifyMarker() {
        do {
            if let marker = try ZagSelfUpdateKeychainProbe.read() {
                markerStatus = "READABLE (ending " + String(marker.suffix(8)) + ")"
            } else {
                markerStatus = "NOT CREATED"
            }
        } catch {
            markerStatus = "FAIL — " + error.localizedDescription
        }
    }

    @State private var readinessStatus = "Not checked"
    @State private var readinessDetails: [(key: String, value: String)] = []

    private func checkRecoveryReadiness() {
        var items: [(key: String, value: String)] = []
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.predicate = NSPredicate(format: "identifier == %@", identifier)
        do {
            let candidates = try Storage.shared.context.fetch(request)
            items.append((key: "Signed candidates", value: String(candidates.count)))
            if candidates.count == 1, let signed = candidates.first {
                if let url = Storage.shared.getAppDirectory(for: signed),
                   let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
                   let name = info["CFBundleExecutable"] as? String,
                   let current = Bundle.main.executableURL {
                    let replacement = url.appendingPathComponent(name)
                    let candidateData = try Data(contentsOf: replacement, options: .mappedIfSafe)
                    let currentData = try Data(contentsOf: current, options: .mappedIfSafe)
                    let candidateHash = SHA256.hash(data: candidateData)
                    let currentHash = SHA256.hash(data: currentData)
                    let different = candidateHash != currentHash
                    items.append((key: "Different executable", value: different ? "YES" : "NO — same binary"))
                    items.append((key: "Candidate version", value: (info["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info["CFBundleVersion"] as? String ?? "?") + ")"))
                } else {
                    items.append((key: "Candidate executable", value: "UNVERIFIED — not accessible"))
                }
            } else {
                items.append((key: "Candidate selection", value: "UNVERIFIED — exactly one required"))
            }
        } catch {
            items.append((key: "Candidate inspection", value: "UNVERIFIED — " + error.localizedDescription))
        }
        do {
            items.append((key: "Keychain marker", value: try ZagSelfUpdateKeychainProbe.read() == nil ? "MISSING" : "READABLE"))
        } catch {
            items.append((key: "Keychain marker", value: "UNVERIFIED — " + error.localizedDescription))
        }
        items.append((key: "Recovery IPA", value: "NOT VERIFIED — requires independent safe reinstall path"))
        items.append((key: "App data recovery", value: "NOT VERIFIED — no validated restore procedure"))
        readinessDetails = items
        readinessStatus = "Recovery not ready — diagnostic only"
    }
    @State private var exportURL: URL?
    @State private var exportStatus = "Not exported"

    private func prepareRepositoryExport() {
        exportURL = nil
        do {
            let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
            let sources = try Storage.shared.context.fetch(request)
            let repositories: [[String: String]] = sources.compactMap { source in
                guard let url = source.sourceURL,
                      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      ["https", "http"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
                // Avoid exporting URL-embedded passwords, access tokens, or fragments.
                parts.user = nil
                parts.password = nil
                parts.query = nil
                parts.fragment = nil
                guard let safeURL = parts.url else { return nil }
                return ["name": source.name ?? "Unnamed Repository", "url": safeURL.absoluteString]
            }
            let payload: [String: Any] = [
                "format": "zag-store-repository-export-v1",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "repositories": repositories
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let directory = FileManager.default.temporaryDirectory
            let file = directory.appendingPathComponent("ZagStore-Repositories.json")
            try data.write(to: file, options: .atomic)
            exportURL = file
            exportStatus = "Prepared " + String(repositories.count) + " repository URLs. Save outside Zag Store using Share."
        } catch {
            exportStatus = "FAIL — " + error.localizedDescription
        }
    }
    @State private var showImportPicker = false
    @State private var importStatus = "No recovery file selected"
    @State private var importPreview: [(name: String, url: String)] = []
    @State private var settingsExportURL: URL?
    @State private var settingsStatus = "Not exported"

    @State private var showSettingsPicker = false
    @State private var settingsImportStatus = "No settings file selected"
    @State private var pendingThemeColor: String?
    @State private var confirmSettingsRestore = false
    @State private var confirmRepositoryRestore = false
    @State private var repositoryRestoreBusy = false

    private func restoreValidatedRepositories() {
        guard !repositoryRestoreBusy, !importPreview.isEmpty else { return }
        let urls = importPreview.map(\.url)
        let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
        let existing = (try? Storage.shared.context.fetch(request)) ?? []
        let existingURLs = Set(existing.compactMap { $0.sourceURL?.absoluteString })
        let missing = urls.filter { !existingURLs.contains($0) }
        guard !missing.isEmpty else {
            importStatus = "ALREADY RESTORED — all " + String(urls.count) + " repository URLs are present."
            return
        }
        repositoryRestoreBusy = true
        importStatus = "RESTORING — " + String(missing.count) + " missing URLs; " + String(urls.count - missing.count) + " already present."
        RepositoryTransferManager.shared.importRepositories(from: missing.joined(separator: "\n")) { _ in
            DispatchQueue.main.async {
                repositoryRestoreBusy = false
                let check: NSFetchRequest<AltSource> = AltSource.fetchRequest()
                let now = (try? Storage.shared.context.fetch(check)) ?? []
                let currentURLs = Set(now.compactMap { $0.sourceURL?.absoluteString })
                let present = urls.filter { currentURLs.contains($0) }.count
                importStatus = "VERIFIED IN DATABASE — " + String(present) + "/" + String(urls.count) + " repository URLs present. Review Sources for download status."
                if present == urls.count { importPreview = [] }
            }
        }
    }
    private func inspectSettingsFile(_ result: Result<URL, Error>) {
        pendingThemeColor = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 100_000,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["format"] as? String == "zag-store-settings-export-v1",
                  let settings = json["settings"] as? [String: String],
                  settings.keys.allSatisfy({ $0 == "Feather.userTintColor" }) else {
                settingsImportStatus = "INVALID — unsupported settings export"
                return
            }
            guard let color = settings["Feather.userTintColor"] else {
                settingsImportStatus = "VALID — no supported settings to restore"
                return
            }
            let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
            guard hex.count == 6, hex.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0)
            }) else {
                settingsImportStatus = "INVALID — theme colour must be six hexadecimal digits"
                return
            }
            pendingThemeColor = "#" + hex.uppercased()
            settingsImportStatus = "VALIDATED — theme colour " + color + ". No changes applied."
        } catch {
            settingsImportStatus = "UNVERIFIED — " + error.localizedDescription
        }
    }
    private func exportSettings() {
        settingsExportURL = nil
        let keys = ["Feather.userTintColor"]
        var settings: [String: String] = [:]
        for key in keys {
            if let value = UserDefaults.standard.string(forKey: key) { settings[key] = value }
        }
        let payload: [String: Any] = [
            "format": "zag-store-settings-export-v1",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "settings": settings
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZagStore-Settings.json")
            try data.write(to: url, options: .atomic)
            settingsExportURL = url
            settingsStatus = "Prepared " + String(settings.count) + " allowlisted settings. Save externally."
        } catch {
            settingsStatus = "FAIL — " + error.localizedDescription
        }
    }

    private func inspectRecoveryFile(_ result: Result<URL, Error>) {
        importPreview = []
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["format"] as? String == "zag-store-repository-export-v1",
                  let records = json["repositories"] as? [[String: String]],
                  records.count <= 1000 else {
                importStatus = "INVALID — unsupported or oversized repository export"
                return
            }
            var seen = Set<String>()
            var validated: [(name: String, url: String)] = []
            for record in records {
                guard let raw = record["url"], let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      url.host != nil, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil else {
                    importStatus = "INVALID — repository URL failed validation"
                    return
                }
                if seen.insert(raw).inserted {
                    validated.append((name: String((record["name"] ?? "Unnamed").prefix(120)), url: raw))
                }
            }
            importPreview = validated
            importStatus = "VALIDATED — " + String(validated.count) + " unique repositories. Preview only; no changes applied."
        } catch {
            importStatus = "UNVERIFIED — " + error.localizedDescription
        }
    }
    private func compareIdentity() {
        report = []
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.predicate = NSPredicate(format: "identifier == %@", Bundle.main.bundleIdentifier ?? "")
        do {
            let candidates = try Storage.shared.context.fetch(request)
            let signed: Signed
            if let uuid = v2TestCandidate ?? preparedCandidateUUID {
                guard let match = candidates.first(where: { $0.uuid == uuid }) else {
                    checkStatus = "UNVERIFIED — prepared candidate no longer exists"
                    return
                }
                signed = match
            } else {
                guard candidates.count == 1, let only = candidates.first else {
                    checkStatus = candidates.isEmpty ? "UNVERIFIED — no signed candidate" : "UNVERIFIED — multiple candidates; prepare a local IPA to select one"
                    return
                }
                signed = only
            }
            let executable = try coordinator.inspectExecutableEntitlements(signed)
            let provisioning = try coordinator.inspectKeychainProvisioning(signed)
            report = executable.map { (key: "Executable: " + $0.key, value: $0.value) }
                + provisioning.map { (key: "Provisioning: " + $0.key, value: $0.value) }
            // Report the disposable marker's actual group alongside the signed
            // candidate's groups. This is read-only and never inspects credentials.
            do {
                if try ZagSelfUpdateKeychainProbe.read() != nil {
                    let markerGroup = try ZagSelfUpdateKeychainProbe.markerAccessGroup()
                    let candidateGroups = try coordinator.inspectKeychainAccessGroups(signed).candidate
                    report.append((key: "Keychain: Marker access group",
                                   value: markerGroup ?? "UNAVAILABLE"))
                    report.append((key: "Keychain: Marker group in candidate executable",
                                   value: markerGroup.map { candidateGroups.contains($0) ? "YES" : "NO" } ?? "UNVERIFIED"))
                } else {
                    report.append((key: "Keychain: Marker access group", value: "NOT CREATED"))
                    report.append((key: "Keychain: Marker group in candidate executable", value: "UNVERIFIED"))
                }
            } catch {
                report.append((key: "Keychain: Marker group inspection", value: "UNVERIFIED — " + error.localizedDescription))
            }
            report.sort { $0.key < $1.key }
            checkStatus = "Diagnostic comparison complete — not installation authorization"
        } catch {
            checkStatus = "UNVERIFIED — " + error.localizedDescription
        }
    }

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private var verifiedReplacementKey: String? {
        guard coordinator.pendingInstallation == nil,
              let verified = coordinator.lastVerifiedInstallation,
              verified.bundleIdentifier == (Bundle.main.bundleIdentifier ?? ""),
              verified.version == installedVersion,
              verified.build == installedBuild,
              let expected = verified.expectedExecutableSHA256,
              !expected.isEmpty else { return nil }
        return [verified.bundleIdentifier, verified.version, verified.build, expected]
            .joined(separator: "|")
    }

    private var shouldCelebrateVerifiedReplacement: Bool {
        guard let key = verifiedReplacementKey else { return false }
        return acknowledgedReplacement != key
    }

    private var verifiedUpdateCelebration: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Zag Store Updated")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Version \(installedVersion) · Build \(installedBuild)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ZagSelfUpdateRainbowProgress(progress: 1)
                .frame(height: 16)
                .accessibilityLabel("Self-update fully verified")

            Label("Installation verified successfully", systemImage: "checkmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            Text("The running executable exactly matches the signed update prepared before installation. Your replacement is verified.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let key = verifiedReplacementKey {
                    acknowledgedReplacement = key
                }
            } label: {
                Text("Continue to Zag Store")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
    }

    private var gate4ProgressTitle: String {
        switch gate4.gate4State {
        case .idle: return "Waiting to start"
        case .starting: return "Preparing installation"
        case .pairVerified: return "Device pairing verified"
        case .tunnel: return "Connecting to device"
        case .rsd: return "Establishing installation service"
        case .installing: return "Uploading signed update"
        case .uploading: return "Transferring signed IPA"
        case .staged: return "IPA verified — waiting for iOS handoff"
        case .upgradeSubmitted: return "Ready to finish on Home Screen"
        case .progress(let value): return "Installing update — \(value)%"
        case .complete: return "Installer reported completion — verify after relaunch"
        case .failed(let reason): return "Installation error: \(reason)"
        }
    }

    // Only callbacks 208 and 206 contain a real percentage.  In other
    // phases the UI is continuously animated but does not invent a number.
    private var gate4MeasuredPercentage: Int? {
        switch gate4.gate4State {
        case .uploading(let value), .progress(let value):
            return min(max(value, 0), 100)
        default:
            return nil
        }
    }

    private var gate4PhaseLabel: String {
        switch gate4.gate4State {
        case .uploading: return "Uploading update"
        case .staged, .upgradeSubmitted, .progress, .complete:
            return "Finishing installation"
        case .failed: return "Installation interrupted"
        default: return "Preparing update"
        }
    }

    private var gate4StageDescription: String {
        switch gate4.gate4State {
        case .uploading:
            return "Transferring the signed update to your iPhone"
        case .staged, .upgradeSubmitted:
            return "Update transferred. iOS is preparing to replace Zag Store."
        case .progress:
            return "iOS is installing the update"
        case .complete:
            return "Installation reported complete. Reopen Zag Store to verify it."
        default:
            return "Establishing a secure connection"
        }
    }

    private var gate4ShouldShowProgress: Bool {
        if gate4.isGate4Running { return true }
        if case .complete = gate4.gate4State { return true }
        return false
    }

    private var zagDeveloperDiagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Native installer event", value: gate4.gate4LastEvent)
            LabeledContent("Previous event", value: gate4.gate4PreviousEvent)
            LabeledContent("Signed candidate", value: candidateSummary)
            LabeledContent("Installation status", value: installStatus)
            Text("Native installer events are diagnostic information, not proof of successful replacement.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Check Installation Prerequisites") {
                handoffReadiness = coordinator.inspectInstallationHandoffReadiness()
            }
            ForEach(handoffReadiness, id: \.self) { finding in
                Text(finding)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let pending = coordinator.pendingInstallation {
                LabeledContent("Pending version", value: pending.version)
                LabeledContent("Pending build", value: pending.build)
            }
            if let completed = coordinator.lastVerifiedInstallation {
                LabeledContent("Verified build", value: completed.build)
            }
        }
    }

    @ViewBuilder
    private var gate4ProgressDisplay: some View {
        if gate4ShouldShowProgress {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.cyan)
                        .accessibilityHidden(true)
                    Text(gate4PhaseLabel)
                        .font(.headline)
                    Spacer(minLength: 8)
                    if let measured = gate4MeasuredPercentage {
                        Text("\(measured)%")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                    } else {
                        Text("In progress")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                ZagSelfUpdateRainbowProgress(
                    progress: Double(gate4MeasuredPercentage ?? 0) / 100,
                    isIndeterminate: gate4MeasuredPercentage == nil
                )
                .frame(height: 16)
                .accessibilityLabel(gate4MeasuredPercentage == nil
                    ? "Update is in progress"
                    : "Installation stage progress")

                Text(gate4StageDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if coordinator.pendingInstallation != nil {
                    switch gate4.gate4State {
                    case .staged, .upgradeSubmitted, .complete:
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Finish on Home Screen", systemImage: "house.fill")
                                .font(.subheadline.weight(.semibold))
                            Text("After a few seconds, swipe up to the Home Screen normally. Wait for Zag Store to finish updating, then reopen it.")
                                .font(.footnote)
                            Text("Do not force-quit Zag Store or start the installation again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    default:
                        EmptyView()
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @AppStorage("ZagStore.advancedSettingsUnlocked")
    private var zagAdvancedSettingsUnlocked = false

    @State private var showAdvancedTools = false
    @State private var showClearPendingConfirmation = false
    @State private var handoffReadiness: [String] = []

    @State private var preparedCandidateUUID: String?
    @State private var preparedOfficialRelease: ZagSelfUpdateCoordinator.Release?
    @State private var showInstallConfirmation = false
    @State private var installBusy = false
    @State private var installStatus = "No installation attempted"

    private var candidateSummary: String {
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.predicate = NSPredicate(format: "identifier == %@", Bundle.main.bundleIdentifier ?? "")
        guard let matches = try? Storage.shared.context.fetch(request) else {
            return "Unable to inspect signed updates"
        }
        if let uuid = preparedCandidateUUID {
            guard let selected = matches.first(where: { $0.uuid == uuid }) else {
                return "Prepared candidate no longer exists"
            }
            return "Signed candidate: " + (selected.version ?? "Unknown version")
        }
        switch matches.count {
        case 0: return "No signed Zag Store update prepared"
        case 1:
            let candidate = matches[0]
            return "Signed candidate: " + (candidate.version ?? "Unknown version")
        default: return "Multiple signed candidates — selection required"
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ZagStoreUpdateAutomaticPreferencesView()
                } label: {
                    HStack {
                        Text("Automatic Update Checks")
                        Spacer()
                        Text(zagAutoCheckEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    ZagStoreUpdateBetaPreferencesView()
                } label: {
                    HStack {
                        Text("Release Channel")
                        Spacer()
                        Text(zagBetaChannel == "beta" ? "Zag Store Beta" :
                             zagBetaChannel == "nightly" ? "Zag Store Nightly" : "Stable")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Button {
                    guard !releaseCheckBusy else { return }
                    releaseCheckBusy = true
                    releaseCheckStatus = "Checking " + (zagBetaChannel == "off" ? "Stable" : zagBetaChannel.capitalized) + "…"
                    Task { @MainActor in
                        defer { releaseCheckBusy = false }
                        do {
                            let selectedChannel = ZagSelfUpdateCoordinator.UpdateChannel.selected
                            let release = try await coordinator.checkForSelectedChannel()
                            guard selectedChannel == ZagSelfUpdateCoordinator.UpdateChannel.selected else {
                                releaseCheckStatus = "Channel changed — check the selected channel again"
                                return
                            }
                            if let release {
                                releaseCheckStatus = "Available: " + release.version + " (Build " + release.build + ")"
                            } else {
                                releaseCheckStatus = "No newer release on this channel"
                            }
                        } catch {
                            if case ZagSelfUpdateCoordinator.UpdateError.channelNotPublished = error {
                                releaseCheckStatus = "No releases published for this channel yet"
                            } else {
                                releaseCheckStatus = "Check failed: " + error.localizedDescription
                            }
                        }
                    }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(releaseCheckBusy)
                if releaseCheckStatus != "Not checked" {
                    Text(releaseCheckStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let release = coordinator.availableRelease {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .center, spacing: 14) {
                            if let icon = UIImage(named: "AppIcon") ?? ZagSelfUpdateStatusView.installedAppIcon {
                                Image(uiImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                            } else {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 44))
                                    .frame(width: 60, height: 60)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Zag Store \(release.version)")
                                    .font(.headline)
                                Text("Build \(release.build)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(releaseDownloadSize ?? "Checking download size…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        Text(release.releaseNotes ?? "Release notes are not available for this update.")
                            .font(.body)
                        Link("Learn more about this update", destination: URL(string: "https://github.com/zagorskey/zag-store-releases/releases")!)
                            .font(.subheadline)
                        Button {
                            guard !releaseDownloadBusy else { return }
                            releaseDownloadBusy = true
                            Task { @MainActor in
                                defer { releaseDownloadBusy = false }
                                releaseCheckStatus = "Downloading and verifying update…"
                                do {
                                    guard let certificate = await ZagCertificateSelection.chooseForSigning() else {
                                        releaseCheckStatus = "Update cancelled — no signing certificate selected."
                                        return
                                    }
                                    let signed = try await coordinator.prepareSignedUpdate(release, certificate: certificate)
                                    preparedCandidateUUID = signed.uuid
                                    preparedOfficialRelease = release
                                    releaseCheckStatus = "Verified and signed. Confirm installation to continue."
                                    showInstallConfirmation = true
                                } catch {
                                    releaseCheckStatus = "Download failed: " + error.localizedDescription
                                }
                            }
                        } label: {
                            Text(releaseDownloadBusy ? "Preparing Update…" : "Update Now")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .foregroundStyle(.white)
                        .controlSize(.large)
                        .disabled(releaseDownloadBusy)
                        Text("The update will be verified and signed before you confirm installation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .task(id: release.ipaURL) {
                        releaseDownloadSize = nil
                        var request = URLRequest(url: release.ipaURL)
                        request.httpMethod = "HEAD"
                        if let response = try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse,
                           response.statusCode == 200,
                           let length = response.value(forHTTPHeaderField: "Content-Length"),
                           let bytes = Int64(length), bytes > 0 {
                            releaseDownloadSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                        } else {
                            releaseDownloadSize = "Download size unavailable"
                        }
                    }
                }
                if coordinator.availableRelease == nil {
                    Text(coordinator.automaticCheckStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if shouldCelebrateVerifiedReplacement {
                Section {
                    verifiedUpdateCelebration
                }
            }

            Section {
                HStack(spacing: 9) {
                    Image(systemName: "app.badge.checkmark")
                        .foregroundStyle(.secondary)
                    Text("Zag Store \(installedVersion)")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("Build \(installedBuild)")
                        .foregroundStyle(.secondary)
                }
                if coordinator.pendingInstallation != nil {
                    Label("Update awaiting verification", systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if coordinator.lastVerifiedInstallation != nil {
                    Label("Installed update verified", systemImage: "checkmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            if zagAdvancedSettingsUnlocked {
            Section {
                DisclosureGroup("Advanced diagnostics and recovery", isExpanded: $showAdvancedTools) {
                Section("Authenticated Beta v2 — Test Only") {
                    Button {
                        prepareAuthenticatedBetaTest()
                    } label: {
                        Label(v2TestBusy ? "Preparing Verified Beta…" : "Prepare & Verify Beta v2", systemImage: "checkmark.shield")
                    }
                    .disabled(v2TestBusy || gate4.isGate4Running || coordinator.pendingInstallation != nil)
                    Text(v2TestStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let uuid = v2TestCandidate {
                        LabeledContent("Signed candidate", value: String(uuid.prefix(12)) + "…")
                        Text("Candidate prepared for inspection only. This test never authorizes or starts installation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Uses a separate test-only HTTPS manifest and isolated rollback history. The existing v1 updater is unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Signing Identity Comparison") {
                    Button("Compare Installed and Signed Candidate") {
                        compareIdentity()
                    }
                    Text(checkStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(report, id: \.key) { item in
                        LabeledContent(item.key, value: item.value)
                    }
                    Text("Read-only structural diagnostics. No installation or data-preservation guarantee.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Keychain Continuity Test") {
                    Button("Create Test Marker") { createMarker() }
                    Button("Verify Test Marker") { verifyMarker() }
                    Text(markerStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("Disposable device-only marker. Does not access existing certificates or credentials. Verify again after a future in-place update.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Recovery Export — Repositories Only") {
                    Button("Prepare Repository Export") { prepareRepositoryExport() }
                    if let url = exportURL {
                        ShareLink(item: url) { Label("Share Repository Export", systemImage: "square.and.arrow.up") }
                    }
                    Text(exportStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("Exports repository names and sanitized URLs only. URL query strings and credentials are removed. Does not back up settings, databases, certificates, keys, or keychain items. Save the file outside Zag Store.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Recovery Import — Validation") {
                    Button("Choose Repository Recovery File") { showImportPicker = true }
                    Text(importStatus).font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(importPreview.enumerated()), id: \.offset) { item in
                        LabeledContent(item.element.name, value: item.element.url)
                    }
                    if !importPreview.isEmpty {
                        Button("Restore Validated Repositories") { confirmRepositoryRestore = true }
                            .disabled(repositoryRestoreBusy)
                    }
                    Text("Only after confirmation, validated URLs are submitted to Zag Store’s existing repository importer. Review Sources afterward; a successful handoff does not guarantee every remote repository loads.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Settings Recovery Export") {
                    Button("Prepare Settings Export") { exportSettings() }
                    if let url = settingsExportURL {
                        ShareLink(item: url) { Label("Share Settings Export", systemImage: "square.and.arrow.up") }
                    }
                    Text(settingsStatus).font(.footnote).foregroundStyle(.secondary)
                    Button("Choose Settings Recovery File") { showSettingsPicker = true }
                    Text(settingsImportStatus).font(.footnote).foregroundStyle(.secondary)
                    if let color = pendingThemeColor {
                        LabeledContent("Restore theme colour", value: color)
                        Button("Restore Validated Theme Colour") { confirmSettingsRestore = true }
                    }
                    Text("Only explicitly allowlisted non-sensitive settings are included. Certificates, tokens and keychain data are excluded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pending Installation Recovery") {
                    if let pending = coordinator.pendingInstallation {
                        LabeledContent("Unverified attempt", value: "\(pending.version) (Build \(pending.build))")
                        Button("Clear Unverified Installation Record", role: .destructive) {
                            showClearPendingConfirmation = true
                        }
                        .disabled(gate4.isGate4Running || installBusy)
                        Text("Clears only the pending self-update record. Does not remove apps or user data. Only use when no installation is active.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Recovery Readiness") {
                    Button("Check Recovery Readiness") { checkRecoveryReadiness() }
                    Text(readinessStatus).font(.footnote).foregroundStyle(.secondary)
                    ForEach(readinessDetails, id: \.key) { item in
                        LabeledContent(item.key, value: item.value)
                    }
                    Text("This check never installs or replaces the app. A candidate and readable marker do not establish a recovery procedure.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                }
            } footer: {
                Text("Optional troubleshooting and recovery tools. Normal updates should not require manual exports.")
            }
            }

            Section("Self-Update") {
                gate4ProgressDisplay

                if coordinator.pendingInstallation != nil && !gate4.isGate4Running {
                    Label("Installation is awaiting verification", systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                    Text("Do not start another update until this installation is verified.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if installStatus.hasPrefix("FAILED") || installStatus.hasPrefix("UNVERIFIED") {
                    Text(installStatus)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if zagAdvancedSettingsUnlocked {
                    DisclosureGroup("Developer diagnostics") {
                        zagDeveloperDiagnostics
                    }
                }
            }

        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
            inspectRecoveryFile(result)
        }
        .fileImporter(isPresented: $showSettingsPicker, allowedContentTypes: [.json]) { result in
            inspectSettingsFile(result)
        }
        .confirmationDialog("Restore repositories?", isPresented: $confirmRepositoryRestore) {
            Button("Import Validated Repositories") { restoreValidatedRepositories() }
        } message: {
            Text("Submit " + String(importPreview.count) + " validated URLs to the existing repository importer. Existing sources are not deliberately deleted.")
        }
        .confirmationDialog("Restore theme colour?", isPresented: $confirmSettingsRestore) {
            Button("Restore Theme Colour") {
                if let color = pendingThemeColor {
                    UserDefaults.standard.set(color, forKey: "Feather.userTintColor")
                    settingsImportStatus = "RESTORED — theme colour " + color
                    pendingThemeColor = nil
                }
            }
        } message: {
            Text("Only the Zag Store theme colour will change. No signing data, repositories, or other settings will be modified.")
        }
        .confirmationDialog("Clear unverified installation record?", isPresented: $showClearPendingConfirmation, titleVisibility: .visible) {
            Button("Clear Pending Record", role: .destructive) {
                guard !gate4.isGate4Running && !installBusy else { return }
                coordinator.clearFailedHandoff()
                handoffReadiness = []
                installStatus = "Previous unverified record cleared; no installation performed"
            }
        } message: {
            Text("This only removes the old pending verification record. It cannot cancel a native installation already in progress or prove that the earlier replacement failed.")
        }
        .confirmationDialog("Replace the installed Zag Store?", isPresented: $showInstallConfirmation, titleVisibility: .visible) {
            Button("Attempt In-Place Replacement", role: .destructive) {
                guard let uuid = preparedCandidateUUID,
                      let release = preparedOfficialRelease,
                      !installBusy, !gate4.isGate4Running else { return }
                installBusy = true
                installStatus = "Submitting upgrade-only installation; app may close"
                Task { @MainActor in
                    defer { installBusy = false }
                    do {
                        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
                        request.fetchLimit = 1
                        request.predicate = NSPredicate(format: "uuid == %@", uuid)
                        guard let candidate = try Storage.shared.context.fetch(request).first else {
                            installStatus = "FAILED — selected candidate missing"
                            return
                        }
                        try await coordinator.installVerifiedSignedUpdate(candidate, release: release, userConfirmedSelfReplacement: true)
                        installStatus = "Installer returned; reopen to verify actual replacement"
                    } catch {
                        installStatus = "UNVERIFIED — " + error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Zag Store will attempt an in-place upgrade using the selected signed update. iOS may close the app during replacement. No automatic uninstall or fresh-install fallback will be attempted. Continue only if you have a recovery copy.")
        }
        .navigationTitle("Zag Store Update")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// The rotating spectrum and five-second linear animation are intentionally
// identical to ZagRepositoryFeaturedPill in SourceAppsView.swift.
private struct ZagSelfUpdateRainbowProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    let progress: Double
    var isIndeterminate = false

    private let spectrum: [Color] = [
        Color(red: 0.00, green: 0.86, blue: 1.00),
        Color(red: 0.05, green: 0.37, blue: 1.00),
        Color(red: 0.42, green: 0.18, blue: 1.00),
        Color(red: 0.95, green: 0.16, blue: 0.89),
        Color(red: 0.00, green: 0.86, blue: 1.00)
    ]

    var body: some View {
        GeometryReader { geometry in
            let fraction = isIndeterminate ? 1 : min(max(progress, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: spectrum,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * fraction)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        AngularGradient(
                            colors: spectrum,
                            center: .center,
                            angle: .degrees(rotating ? 360 : 0)
                        ),
                        lineWidth: 1.5
                    )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: progress)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                rotating = true
            }
        }
    }
}


// Automatic installation is still disabled; channel selection controls manual checks.
private struct ZagStoreUpdateAutomaticPreferencesView: View {
    @AppStorage("ZagStore.updatePreferences.automaticChecks.v1")
    private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Automatically Check for Updates", isOn: $enabled)
                    .tint(.green)
                    .onChange(of: enabled) { _ in
                        ZagSelfUpdateCoordinator.shared.preferencesChanged()
                    }
            } footer: {
                Text("Checks for updates on launch and when returning to Zag Store. Downloads and installation require your approval.")
            }
        }
        .navigationTitle("Automatic Update Checks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ZagStoreUpdateBetaPreferencesView: View {
    @AppStorage("ZagStore.updatePreferences.betaChannel.placeholder")
    private var channel = "off"

    var body: some View {
        Form {
            Section {
                ForEach(["off", "beta", "nightly"], id: \.self) { option in
                    Button {
                        channel = option
                        ZagSelfUpdateCoordinator.shared.preferencesChanged()
                    } label: {
                        HStack {
                            Text(option == "beta" ? "Zag Store Beta" :
                                 option == "nightly" ? "Zag Store Nightly" : "Stable")
                                .foregroundStyle(.primary)
                            Spacer()
                            if channel == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text("Select the release channel. Switching channels clears the previous update and checks the new channel when automatic checks are enabled.")
            }
        }
        .navigationTitle("Release Channel")
        .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI
import CoreData
import ZsignSwift

/// Read-only development diagnostics. Never initiates installation.
struct ZagSelfUpdateSignatureDiagnosticsView: View {
    @FetchRequest(
        entity: Signed.entity(),
        sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
    ) private var signedApps: FetchedResults<Signed>

    @State private var preflightReport: [(String, String)] = []
    @State private var probeMessage: String?
    @State private var report: [(String, String)] = []
    @State private var provisioningReport: [(String, String)] = []
    @State private var installedGroups: [String] = []
    @State private var candidateGroups: [String] = []
    @State private var errorMessage: String?
    @State private var selectedUUID: String = ""
    @State private var hashTestUUID: String = ""
    @State private var hashTestResult: String?
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
    ) private var testCertificates: FetchedResults<CertificatePair>
    @State private var testCertificateUUID = ""
    @State private var sha256TestResult: String?
    @State private var installedIdentityResult: String?
    @State private var sha256TestRunning = false

    private var candidates: [Signed] {
        signedApps.filter { $0.identifier == Bundle.main.bundleIdentifier }
    }

    var body: some View {
        Form {
            Section {
                Text("Read-only comparison of embedded XML code-signature entitlements. This does not verify cryptographic signatures or install an update.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if candidates.isEmpty {
                    Text("No signed Zag Store candidate in Library.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Signed candidate", selection: $selectedUUID) {
                        Text("Select candidate").tag("")
                        ForEach(candidates, id: \.uuid) { app in
                            Text("\(app.version ?? "Unknown") — \(app.uuid ?? "")")
                                .tag(app.uuid ?? "")
                        }
                    }

                Button("Inspect Installed Zag Store") {
                    installedIdentityResult = inspectInstalledZagStore()
                }

                if let installedIdentityResult {
                    Text(installedIdentityResult)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

Button("Inspect Entitlements") {
                        inspect()
                    }
                    .disabled(selectedUUID.isEmpty)
                }
            } header: {
                Text("Self-Update Candidate")
            }
            Section("Signed App Hash Test") {
                Text("Inspect the primary CodeDirectory of any signed app. Read-only: does not sign, install, or verify CMS authenticity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if signedApps.isEmpty {
                    Text("No signed apps in Library.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Signed app", selection: $hashTestUUID) {
                        Text("Select signed app").tag("")
                        ForEach(signedApps, id: \.uuid) { app in
                            Text("\(app.name ?? app.identifier ?? "Unknown") — \(app.version ?? "?")")
                                .tag(app.uuid ?? "")
                        }
                    }
                    Button("Inspect CodeDirectory Hashes") {
                        hashTestResult = nil
                        guard let candidate = signedApps.first(where: { $0.uuid == hashTestUUID }),
                              let appURL = Storage.shared.getAppDirectory(for: candidate),
                              let executableURL = Bundle(url: appURL)?.executableURL else {
                            hashTestResult = "UNVERIFIED — signed app or executable not found"
                            return
                        }
                        do {
                            hashTestResult = try ZagMachOSignatureInspector.inspectCodePageHashes(at: executableURL)
                        } catch {
                            hashTestResult = "UNVERIFIED — \(error.localizedDescription)"
                        }
                    }
                    .disabled(hashTestUUID.isEmpty)
                }
                if let hashTestResult {
                    Text(hashTestResult)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            Section("Experimental SHA-256 Signing") {
                Text("Signs only a temporary copy of the signed app selected above. Never installs, updates, or changes Library contents. Checks SHA-256 code pages, CMS authenticity, Apple hash-agility attributes and the X.509 certificate path. Does not authorize installation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Test certificate", selection: $testCertificateUUID) {
                    Text("Select certificate").tag("")
                    ForEach(testCertificates, id: \.uuid) { cert in
                        Text(cert.nickname ?? cert.uuid ?? "Unnamed certificate")
                            .tag(cert.uuid ?? "")
                    }
                }
                Button(sha256TestRunning ? "Signing temporary copy…" : "Test SHA-256 Signing") {
                    Task { await runSHA256Test() }
                }
                .disabled(sha256TestRunning || hashTestUUID.isEmpty || testCertificateUUID.isEmpty)
                if let sha256TestResult {
                    Text(sha256TestResult)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            Section("Self-Update Preflight") {
                Text("Read-only structural checks. Experimental CMS verification is available above; this preflight does not authorize installation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Run Preflight") {
                    preflightReport = []
                    if let candidate = candidates.first(where: { $0.uuid == selectedUUID }) {
                        let results = ZagSelfUpdateCoordinator.shared.inspectSelfUpdatePreflight(candidate)
                        preflightReport = results.keys.sorted().map { ($0, results[$0] ?? "") }
                    } else {
                        preflightReport = [("Candidate", "Select a signed Zag Store candidate first")]
                    }
                }
                .disabled(selectedUUID.isEmpty)
                ForEach(preflightReport, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.0).font(.subheadline)
                        Text(item.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Keychain Continuity Probe") {
                Text("Create a disposable marker before an update. After a separately confirmed update, use Read Marker to check whether it survived. This never reads existing app credentials.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Create or Read Marker") {
                    do {
                        let marker = try ZagSelfUpdateKeychainProbe.createIfMissing()
                        probeMessage = "Marker available: \(marker)"
                    } catch {
                        probeMessage = error.localizedDescription
                    }
                }
                Button("Read Existing Marker") {
                    do {
                        if let marker = try ZagSelfUpdateKeychainProbe.read() {
                            probeMessage = "Marker readable: \(marker)"
                        } else {
                            probeMessage = "No marker found."
                        }
                    } catch {
                        probeMessage = error.localizedDescription
                    }
                }
                Button("Delete Test Marker", role: .destructive) {
                    do {
                        try ZagSelfUpdateKeychainProbe.remove()
                        probeMessage = "Test marker removed."
                    } catch {
                        probeMessage = error.localizedDescription
                    }
                }
                if let probeMessage {
                    Text(probeMessage).font(.footnote).textSelection(.enabled)
                }
            }
            if let errorMessage {
                Section("Inspection Error") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            if !report.isEmpty {
                Section("Provisioning Profile Comparison") {
                    ForEach(provisioningReport, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.0).font(.subheadline)
                            Text(item.1).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                Section("Installed Keychain Groups") {
                    if installedGroups.isEmpty { Text("None reported") }
                    ForEach(installedGroups, id: \.self) { Text($0).font(.footnote).textSelection(.enabled) }
                }
                Section("Candidate Keychain Groups") {
                    if candidateGroups.isEmpty { Text("None reported") }
                    ForEach(candidateGroups, id: \.self) { Text($0).font(.footnote).textSelection(.enabled) }
                }

                Section("Executable Entitlements") {
                    ForEach(report, id: \.0) { item in
                        LabeledContent(item.0, value: item.1)
                    }
                }
            }
        }
        .navigationTitle("Signature Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor

    private func inspectInstalledZagStore() -> String {
        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier ?? "UNKNOWN"

        guard let executable = bundle.executableURL else {
            return "FAIL — installed executable unavailable"
        }

        var lines = [
            "INSTALLED ZAG STORE — READ ONLY",
            "Bundle ID: \(bundleID)"
        ]

        do {
            let entitlements =
                try ZagMachOSignatureInspector.entitlements(
                    at: executable
                )

            let appID =
                entitlements["application-identifier"] as? String
                ?? "MISSING"

            let team =
                entitlements[
                    "com.apple.developer.team-identifier"
                ] as? String ?? "MISSING"

            let groups =
                entitlements["keychain-access-groups"]
                as? [String] ?? []

            lines.append("Executable App ID: \(appID)")
            lines.append("Executable Team: \(team)")
            lines.append("Executable Keychain Groups: \(groups)")
        } catch {
            lines.append(
                "Executable inspection FAILED: \(error.localizedDescription)"
            )
        }

        let profileURL = bundle.bundleURL.appendingPathComponent(
            "embedded.mobileprovision"
        )

        if let profile = CertificateReader(profileURL).decoded {
            let team = profile.TeamIdentifier.first ?? "MISSING"

            let appID =
                profile.Entitlements?[
                    "application-identifier"
                ]?.value as? String ?? "MISSING"

            let groups =
                profile.Entitlements?[
                    "keychain-access-groups"
                ]?.value as? [String] ?? []

            let expected = team + "." + bundleID

            lines.append("Profile Team: \(team)")
            lines.append("Profile App ID: \(appID)")
            lines.append("Expected App ID: \(expected)")
            lines.append(
                "Bundle/Profile Match: " + (appID == expected ? "YES" : "NO")
            )
            lines.append("Profile Keychain Groups: \(groups)")
            lines.append(
                "Profile Expiration: \(profile.ExpirationDate)"
            )
        } else {
            lines.append("Provisioning profile: UNAVAILABLE")
        }

        lines.append("Installation authorization: NOT VERIFIED")

        return lines.joined(separator: "\n")
    }

    private func runSHA256Test() async {
        guard !sha256TestRunning else { return }
        sha256TestRunning = true
        sha256TestResult = "Preparing disposable app copy…"
        defer { sha256TestRunning = false }

        guard let app = signedApps.first(where: { $0.uuid == hashTestUUID }),
              let sourceURL = Storage.shared.getAppDirectory(for: app),
              let certificate = testCertificates.first(where: { $0.uuid == testCertificateUUID }) else {
            sha256TestResult = "UNVERIFIED — select an existing signed app and certificate."
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zag-sha256-experiment-\(UUID().uuidString)", isDirectory: true)
        let copyURL = directory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.copyItem(at: sourceURL, to: copyURL)

            var options = Options.defaultOptions
            options.appEntitlementsFile = nil
            options.removeProvisioning = false
            let signer = ZsignHandler(appUrl: copyURL, options: options, cert: certificate)
            try await signer.sign(sha256Only: true)
            if let error = signer.hadError { throw error }
            guard let executable = Bundle(url: copyURL)?.executableURL else {
                sha256TestResult = "UNVERIFIED — executable missing after signing."
                return
            }
            let result = try ZagMachOSignatureInspector.inspectCodePageHashes(at: executable)
            guard result.hasPrefix("PASS —"),
                  result.contains("SHA-256 code pages") else {
                sha256TestResult = "UNVERIFIED — expected SHA-256 integrity PASS; got: \(result)"
                return
            }

            let inputs = try ZagMachOSignatureInspector
                .extractDetachedCMSInputs(at: executable)

            let cmsResult = Zsign.verifyDetachedCMS(
                cms: inputs.cms,
                codeDirectory: inputs.codeDirectory
            )

            let chainResult = Zsign.inspectCMSCertificateChain(
                cms: inputs.cms
            )

            let appleTrustResult = Zsign.inspectAppleSecurityTrust(
                cms: inputs.cms
            )


            // Read-only audit of the temporary signed application.
            // Profile decoding does not establish CMS authenticity.
            let profileURL = copyURL.appendingPathComponent(
                "embedded.mobileprovision"
            )

            var profileAudit = "UNVERIFIED — embedded provisioning profile missing or unreadable"

            if let profile = CertificateReader(profileURL).decoded {
                let bundleID = Bundle(url: copyURL)?.bundleIdentifier ?? ""
                let team = profile.TeamIdentifier.first ?? ""

                let appID = profile.Entitlements?[
                    "application-identifier"
                ]?.value as? String ?? ""

                let expectedAppID = team.isEmpty
                    ? ""
                    : team + "." + bundleID

                let appIDMatches = !expectedAppID.isEmpty
                    && appID == expectedAppID

                let notExpired = profile.ExpirationDate > Date()

                let groups = profile.Entitlements?[
                    "keychain-access-groups"
                ]?.value as? [String] ?? []

                profileAudit = """
                Profile decoded: YES (authenticity UNVERIFIED)
                Bundle identifier: \(bundleID)
                Provisioning team: \(team)
                Profile application identifier: \(appID)
                Explicit App ID match: \(appIDMatches ? "YES" : "NO")
                Profile expiration: \(profile.ExpirationDate)
                Profile not expired: \(notExpired ? "YES" : "NO")
                Profile keychain groups: \(groups.count)
                Developer certificate match: NOT CHECKED
                This device authorized: NOT CHECKED
                Profile CMS authenticity: NOT VERIFIED
                DER profile consistency: NOT VERIFIED
                Executable entitlement compatibility: NOT CHECKED
                """
            }

            sha256TestResult = """
            SHA-256 EXPERIMENT — \(result)
            CMS — \(cmsResult)
            Certificate chain — \(chainResult)
            Apple Security trust — \(appleTrustResult)
            PROVISIONING PROFILE AUDIT
            \(profileAudit)
            Apple hash-agility V2: see CMS verification result.
            Certificate trust: see X.509 chain result; Apple policy and revocation unverified.
            Installation authorization: NOT ESTABLISHED.
            Temporary copy cleanup scheduled.
            """
        } catch {
            sha256TestResult = "UNVERIFIED — \(error.localizedDescription). Temporary copy cleanup attempted."
        }
    }

    private func inspect() {
        report = []
        provisioningReport = []
        installedGroups = []
        candidateGroups = []
        errorMessage = nil
        guard let candidate = candidates.first(where: { $0.uuid == selectedUUID }) else {
            errorMessage = "Choose a signed Zag Store candidate."
            return
        }
        do {
            let result = try ZagSelfUpdateCoordinator.shared.inspectExecutableEntitlements(candidate)
            report = result.keys.sorted().map { ($0, result[$0] ?? "") }
            let groups = try ZagSelfUpdateCoordinator.shared.inspectKeychainAccessGroups(candidate)
            installedGroups = groups.installed
            candidateGroups = groups.candidate
            let profiles = try ZagSelfUpdateCoordinator.shared.inspectKeychainProvisioning(candidate)
            provisioningReport = profiles.keys.sorted().map { ($0, profiles[$0] ?? "") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

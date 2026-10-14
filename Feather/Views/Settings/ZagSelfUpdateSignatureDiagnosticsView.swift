import SwiftUI
import CoreData

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
                Text("Signs only a temporary copy of the signed app selected above. Never installs, updates, or changes Library contents. A hash PASS does not verify CMS authenticity.")
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
                Text("Read-only structural checks. Cryptographic signature verification is not implemented; this cannot authorize installation.")
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
            sha256TestResult = result.contains("SHA-256")
                ? "SHA-256 EXPERIMENT — \(result)\nCMS authenticity and installation remain UNVERIFIED. Temporary copy deleted."
                : "UNVERIFIED — expected SHA-256 primary CodeDirectory; got: \(result)"
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

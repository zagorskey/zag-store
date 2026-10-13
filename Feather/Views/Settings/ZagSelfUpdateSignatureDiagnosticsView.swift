import SwiftUI
import CoreData

/// Read-only development diagnostics. Never initiates installation.
struct ZagSelfUpdateSignatureDiagnosticsView: View {
    @FetchRequest(
        entity: Signed.entity(),
        sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
    ) private var signedApps: FetchedResults<Signed>

    @State private var probeMessage: String?
    @State private var report: [(String, String)] = []
    @State private var provisioningReport: [(String, String)] = []
    @State private var installedGroups: [String] = []
    @State private var candidateGroups: [String] = []
    @State private var errorMessage: String?
    @State private var selectedUUID: String = ""

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

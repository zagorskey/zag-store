import SwiftUI
import CoreData

/// Read-only development diagnostics. Never initiates installation.
struct ZagSelfUpdateSignatureDiagnosticsView: View {
    @FetchRequest(
        entity: Signed.entity(),
        sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
    ) private var signedApps: FetchedResults<Signed>

    @State private var report: [(String, String)] = []
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
            if let errorMessage {
                Section("Inspection Error") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            if !report.isEmpty {
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
        errorMessage = nil
        guard let candidate = candidates.first(where: { $0.uuid == selectedUUID }) else {
            errorMessage = "Choose a signed Zag Store candidate."
            return
        }
        do {
            let result = try ZagSelfUpdateCoordinator.shared.inspectExecutableEntitlements(candidate)
            report = result.keys.sorted().map { ($0, result[$0] ?? "") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

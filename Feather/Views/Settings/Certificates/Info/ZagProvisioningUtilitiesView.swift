//
//  ZagProvisioningUtilitiesView.swift
//  Zag Store
//
//  Read-only local profile inspection and comparison. No signing changes.
//

import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct ZagProvisioningProfileInspectorView: View {
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
    ) private var certificates: FetchedResults<CertificatePair>

    @AppStorage("feather.selectedCert") private var selectedCert = 0
    @State private var importing = false
    @State private var profile: Certificate?
    @State private var filename: String?
    @State private var errorMessage: String?
    @State private var referenceIndex = 0

    var body: some View {
        Form {
            Section {
                Button {
                    importing = true
                } label: {
                    Label(profile == nil ? "Choose Provisioning Profile" : "Choose Another Profile",
                          systemImage: "doc.badge.plus")
                }
                if let filename {
                    LabeledContent("Selected File", value: filename)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                        .font(.subheadline)
                }
            } header: {
                Text("Standalone Inspector")
            } footer: {
                Text("Read-only inspection of a .mobileprovision file. The file is not imported into your signing library.")
            }

            if let profile {
                Section {
                    LabeledContent("Name", value: profile.Name)
                    LabeledContent("Team", value: profile.TeamName)
                    LabeledContent("Team ID", value: profile.TeamIdentifier.joined(separator: ", "))
                    LabeledContent("Profile UUID", value: profile.UUID)
                        .copyableText(profile.UUID)
                    LabeledContent("App ID Pattern", value: ZagProfileComparison.appID(profile))
                    LabeledContent("Platform", value: profile.Platform.joined(separator: ", "))
                    LabeledContent("Expires") { Text(profile.ExpirationDate, style: .date) }
                    LabeledContent("Registered Devices",
                                   value: String(profile.ProvisionedDevices?.count ?? 0))
                    LabeledContent("Entitlement Keys",
                                   value: String(profile.Entitlements?.count ?? 0))
                    LabeledContent("Embedded Certificates",
                                   value: String(profile.DeveloperCertificates?.count ?? 0))
                } header: {
                    Text("Profile Information")
                }

                if !certificates.isEmpty {
                    Section {
                        Picker("Compare Against", selection: $referenceIndex) {
                            ForEach(Array(certificates.enumerated()), id: \.offset) { item in
                                Text(item.element.nickname
                                     ?? Storage.shared.getProvisionFileDecoded(for: item.element)?.Name
                                     ?? "Certificate \(item.offset + 1)")
                                    .tag(item.offset)
                            }
                        }

                        if certificates.indices.contains(referenceIndex),
                           let stored = Storage.shared.getProvisionFileDecoded(for: certificates[referenceIndex]) {
                            NavigationLink {
                                ZagProfileComparisonView(
                                    first: stored, second: profile,
                                    firstLabel: "Stored", secondLabel: "Imported"
                                )
                            } label: {
                                Label("Compare Profiles", systemImage: "arrow.left.arrow.right")
                            }
                        } else {
                            Label("Stored provisioning profile unavailable", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Compare With Signing Library")
                    } footer: {
                        Text("Differences are informational, not a guarantee of signing or installation.")
                    }
                }
            }
        }
        .navigationTitle("Profile Inspector")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if certificates.indices.contains(selectedCert) { referenceIndex = selectedCert }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mobileProvision]) { result in
            switch result {
            case .success(let url): _load(url)
            case .failure: errorMessage = "Could not open the selected file."
            }
        }
    }

    private func _load(_ url: URL) {
        profile = nil
        filename = nil
        errorMessage = nil

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024 else {
                errorMessage = "Select a regular provisioning profile smaller than 16 MB."
                return
            }

            let bytes = try Data(contentsOf: url)
            guard let start = bytes.range(of: Data("<?xml".utf8)),
                  let end = bytes.range(of: Data("</plist>".utf8),
                                        options: [], in: start.lowerBound..<bytes.endIndex) else {
                errorMessage = "No readable XML provisioning profile was found."
                return
            }

            let plist = bytes.subdata(in: start.lowerBound..<end.upperBound)
            profile = try PropertyListDecoder().decode(Certificate.self, from: plist)
            filename = url.lastPathComponent
        } catch {
            errorMessage = "This provisioning profile could not be decoded."
        }
    }
}

struct ZagStoredProfileComparisonView: View {
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
    ) private var certificates: FetchedResults<CertificatePair>

    @AppStorage("feather.selectedCert") private var selectedCert = 0
    @State private var firstIndex = 0
    @State private var secondIndex = 1

    var body: some View {
        Form {
            if certificates.count < 2 {
                Section {
                    Label("Two stored identities are required", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        ZagProvisioningProfileInspectorView()
                    } label: {
                        Label("Inspect an External Profile", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Compare Stored Profiles")
                } footer: {
                    Text("Compare an external profile with your current signing identity without importing a P12.")
                }
            } else {
                Section {
                    Picker("First Identity", selection: $firstIndex) {
                        ForEach(Array(certificates.enumerated()), id: \.offset) { item in
                            Text(_name(item.element, index: item.offset)).tag(item.offset)
                        }
                    }
                    Picker("Second Identity", selection: $secondIndex) {
                        ForEach(Array(certificates.enumerated()), id: \.offset) { item in
                            Text(_name(item.element, index: item.offset)).tag(item.offset)
                        }
                    }
                } header: {
                    Text("Choose Profiles")
                }

                Section {
                    if firstIndex == secondIndex {
                        Label("Choose two different signing identities", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else if certificates.indices.contains(firstIndex),
                              certificates.indices.contains(secondIndex),
                              let first = Storage.shared.getProvisionFileDecoded(for: certificates[firstIndex]),
                              let second = Storage.shared.getProvisionFileDecoded(for: certificates[secondIndex]) {
                        NavigationLink {
                            ZagProfileComparisonView(
                                first: first, second: second,
                                firstLabel: "First", secondLabel: "Second"
                            )
                        } label: {
                            Label("Compare Profiles", systemImage: "arrow.left.arrow.right")
                        }
                    } else {
                        Label("One or both provisioning profiles are unavailable",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                    }
                } header: {
                    Text("Comparison")
                } footer: {
                    Text("Read-only comparison. Private keys and P12 passwords are not accessed.")
                }
            }
        }
        .navigationTitle("Compare Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if certificates.indices.contains(selectedCert) {
                firstIndex = selectedCert
                secondIndex = firstIndex == 0 ? 1 : 0
            }
        }
    }

    private func _name(_ cert: CertificatePair, index: Int) -> String {
        cert.nickname
            ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name
            ?? "Certificate \(index + 1)"
    }
}

private enum ZagProfileComparison {
    static func appID(_ profile: Certificate) -> String {
        profile.Entitlements?["application-identifier"]?.value as? String
            ?? profile.Entitlements?["com.apple.application-identifier"]?.value as? String
            ?? "Not specified"
    }

    static func certificateHashes(_ profile: Certificate) -> Set<String> {
        Set((profile.DeveloperCertificates ?? []).map { der in
            SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        })
    }

    static func scope(_ profile: Certificate) -> String {
        if profile.ProvisionsAllDevices == true { return "Enterprise / all devices" }
        if let devices = profile.ProvisionedDevices { return "\(devices.count) listed devices" }
        return "No embedded device list"
    }
}

struct ZagProfileComparisonView: View {
    let first: Certificate
    let second: Certificate
    let firstLabel: String
    let secondLabel: String

    private var firstKeys: Set<String> {
        Set(first.Entitlements?.map { $0.key } ?? [])
    }
    private var secondKeys: Set<String> {
        Set(second.Entitlements?.map { $0.key } ?? [])
    }

    var body: some View {
        let sharedKeys = firstKeys.intersection(secondKeys)
        let firstOnly = firstKeys.subtracting(secondKeys).sorted()
        let secondOnly = secondKeys.subtracting(firstKeys).sorted()
        let firstHashes = ZagProfileComparison.certificateHashes(first)
        let secondHashes = ZagProfileComparison.certificateHashes(second)

        Form {
            Section {
                Label("Local provisioning profile comparison", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.medium))
                Text("Differences are not signing failures. App ID patterns and entitlement values require separate compatibility checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Comparison Scope")
            }

            Section {
                _comparisonRow("Team ID",
                               first.TeamIdentifier.joined(separator: ", "),
                               second.TeamIdentifier.joined(separator: ", "))
                _comparisonRow("App ID Pattern",
                               ZagProfileComparison.appID(first),
                               ZagProfileComparison.appID(second))
                _comparisonRow("Platform",
                               first.Platform.sorted().joined(separator: ", "),
                               second.Platform.sorted().joined(separator: ", "))
                _comparisonRow("Device Scope",
                               ZagProfileComparison.scope(first),
                               ZagProfileComparison.scope(second))
                _comparisonRow("Profile UUID", first.UUID, second.UUID)
            } header: {
                Text("Identity & Provisioning")
            }

            Section {
                LabeledContent("\(firstLabel) Expires") {
                    Text(first.ExpirationDate, style: .date)
                }
                LabeledContent("\(secondLabel) Expires") {
                    Text(second.ExpirationDate, style: .date)
                }
                LabeledContent("Same Embedded Certificates",
                               value: firstHashes == secondHashes ? "Yes" : "No")
                LabeledContent("Shared Certificate Fingerprints",
                               value: String(firstHashes.intersection(secondHashes).count))
            } header: {
                Text("Validity & Certificates")
            }

            Section {
                LabeledContent("Shared Entitlement Keys", value: String(sharedKeys.count))
                _keyList("\(firstLabel) Only", keys: firstOnly)
                _keyList("\(secondLabel) Only", keys: secondOnly)
            } header: {
                Text("Entitlement Key Comparison")
            } footer: {
                Text("Only entitlement key presence is compared, not values. Missing or different keys do not automatically mean an app cannot be signed.")
            }
        }
        .navigationTitle("Profile Differences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func _comparisonRow(_ title: String, _ a: String, _ b: String) -> some View {
        DisclosureGroup {
            LabeledContent(firstLabel) {
                Text(a)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(secondLabel) {
                Text(b)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Label(a == b ? "Same" : "Different",
                      systemImage: a == b ? "equal.circle" : "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func _keyList(_ title: String, keys: [String]) -> some View {
        if keys.isEmpty {
            LabeledContent(title, value: "None")
        } else {
            DisclosureGroup("\(title) (\(keys.count))") {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .copyableText(key)
                }
            }
        }
    }
}

//
//  CertificatesInfoView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews
import ZsignSwift
import CryptoKit
import Security

// MARK: - View
struct CertificatesInfoView: View {
	@Environment(\.dismiss) var dismiss
	@State var data: Certificate?
    @State private var _identityCheck: ZagP12IdentityCheck.Result?
    @State private var _identityCheckRunning = false
    @State private var _testBundleID = ""
    @State private var _testDeviceUDID = ""
    @State private var _requestedEntitlementsText = ""
    @State private var _entitlementCheck: ZagEntitlementCompatibility.Result?
	
	var cert: CertificatePair
	
    // MARK: - Certificate details hub
    var body: some View {
        Form {
            if let data {
                Section {
                    _identityHero(data: data)
                } header: {
                    Text("Signing Identity")
                }

                Section {
                    _overviewStatus(data: data)

                    LabeledContent("Profile Expires") {
                        Text(data.ExpirationDate, format: .dateTime.day().month(.abbreviated).year())
                    }

                    LabeledContent("Provisioning", value: _profileType(data))

                    if let teamID = data.TeamIdentifier.first {
                        LabeledContent("Team ID") {
                            Text(teamID)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        .copyableText(teamID)
                    }
                } header: {
                    Text("At a Glance")
                } footer: {
                    Text("These indicators describe locally available files and profile data. They do not establish Apple revocation status or successful signing.")
                }

                Section {
                    NavigationLink {
                        Form {
                            _diagnosticsSection(data: data)
                            _validitySection(data: data)
                        }
                        .navigationTitle("Signing Diagnostics")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        _destinationLabel(
                            "Signing Diagnostics",
                            subtitle: "P12 verification, profile dates and local checks",
                            symbol: "checkmark.shield"
                        )
                    }

                    NavigationLink {
                        Form {
                            _identitySection(data: data)
                            _certificateFingerprints(data: data)
                            _infoSection(data: data)
                        }
                        .navigationTitle("Certificate & Profile")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        _destinationLabel(
                            "Certificate & Profile",
                            subtitle: "Signing team, identifiers and SHA-256 fingerprints",
                            symbol: "person.text.rectangle"
                        )
                    }

                    NavigationLink {
                        Form {
                            _appCompatibilitySection(data: data)
                            _deviceCompatibilitySection(data: data)
                            _miscSection(data: data)
                        }
                        .navigationTitle("Compatibility")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        _destinationLabel(
                            "Compatibility & Devices",
                            subtitle: "App IDs, provisioning scope and device eligibility",
                            symbol: "iphone.gen3"
                        )
                    }

                    NavigationLink {
                        Form {
                            _entitlementDiagnosticsSection(data: data)
                            _requestedEntitlementsSection(data: data)
                            _entitlementsSection(data: data)
                        }
                        .navigationTitle("Entitlements")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        _destinationLabel(
                            "Entitlements & Capabilities",
                            subtitle: "Profile permissions and requested entitlement checks",
                            symbol: "lock.shield"
                        )
                    }
                } header: {
                    Text("Advanced Inspection")
                } footer: {
                    Text("All inspections are local and read-only. The signing engine is unchanged.")
                }
            } else {
                Section {
                    Label("Provisioning profile unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                    Text("Certificate details cannot be decoded from the imported provisioning profile.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Signing Identity")
                }
            }

            Section {
                NavigationLink {
                    ZagCertificateExportView(cert: cert)
                } label: {
                    Label("Export Signing Files", systemImage: "square.and.arrow.up")
                }

                Button {
                    if let directory = Storage.shared.getUuidDirectory(for: cert),
                       let sharedURL = directory.toSharedDocumentsURL() {
                        UIApplication.open(sharedURL)
                    }
                } label: {
                    Label("Open in Files", systemImage: "folder")
                }
            } header: {
                Text("Files")
            }
        }
        .navigationTitle("Certificate Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close Certificate Details")
            }
        }
        .onAppear {
            data = Storage.shared.getProvisionFileDecoded(for: cert)
        }
    }

    private func _identityHero(data: Certificate) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(cert.nickname ?? data.Name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(data.TeamName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Provisioning profile")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func _overviewStatus(data: Certificate) -> some View {
        let hasP12 = Storage.shared.getFile(.certificate, from: cert) != nil
        let isCurrent = data.CreationDate <= Date() && data.ExpirationDate > Date()
        let hasDeveloperCertificates = !(data.DeveloperCertificates ?? []).isEmpty

        _overviewRow("P12 Signing File", okay: hasP12, success: "Present", failure: "Missing")
        _overviewRow("Profile Dates", okay: isCurrent, success: "Current", failure: "Not current")
        _overviewRow("Developer Certificates", okay: hasDeveloperCertificates,
                     success: "\(data.DeveloperCertificates?.count ?? 0) embedded", failure: "None embedded")
        HStack {
            Label("Apple Revocation", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
            Spacer()
            Text(cert.revoked ? "Previously marked revoked" : "Not verified")
                .font(.subheadline)
                .foregroundStyle(cert.revoked ? Color.orange : Color.secondary)
        }
    }

    private func _overviewRow(
        _ title: String, okay: Bool, success: String, failure: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: okay ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(okay ? Color.green : Color.orange)
            Text(title)
            Spacer(minLength: 8)
            Text(okay ? success : failure)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func _destinationLabel(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
        }
    }
}

// MARK: - Local signing preflight
extension CertificatesInfoView {
    // These checks do not contact Apple, import the P12 into the keychain,
    // expose passwords or claim that the identity can sign an app.
    private func _diagnosticsSection(data: Certificate) -> some View {
        let hasP12 = Storage.shared.getFile(.certificate, from: cert) != nil
        let hasEmbeddedCertificates = !(data.DeveloperCertificates ?? []).isEmpty
        let isCurrent = data.CreationDate <= Date() && data.ExpirationDate > Date()
        let isRevoked = cert.revoked
        let fileReady = hasP12 && hasEmbeddedCertificates && isCurrent && !isRevoked

        return Section {
            HStack(spacing: 10) {
                Image(systemName: fileReady ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(fileReady ? Color.accentColor : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileReady ? "Local preflight passed" : "Local preflight needs attention")
                        .font(.subheadline.weight(.semibold))
                    Text("Signing and Apple revocation status are not verified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            _diagnosticRow(
                "P12 Signing File",
                passed: hasP12,
                success: "Present",
                failure: "Missing"
            )
            _diagnosticRow(
                "Embedded Developer Certificates",
                passed: hasEmbeddedCertificates,
                success: "\(data.DeveloperCertificates?.count ?? 0) found",
                failure: "None found"
            )
            _diagnosticRow(
                "Profile Date Range",
                passed: isCurrent,
                success: "Current",
                failure: "Not currently valid"
            )
            _diagnosticRow(
                "Local Revocation Flag",
                passed: !isRevoked,
                success: "No revocation recorded",
                failure: "Marked revoked"
            )
            LabeledContent("Provisioning Type", value: _profileType(data))
            Button {
                _verifySigningIdentity(data: data)
            } label: {
                HStack(spacing: 8) {
                    if _identityCheckRunning {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text(_identityCheck == nil ? "Verify P12 and Profile Match" : "Verify Again")
                }
            }
            .disabled(_identityCheckRunning || !hasP12 || !hasEmbeddedCertificates)

            if let result = _identityCheck {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.isMatch ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.isMatch ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.subheadline.weight(.semibold))
                        Text(result.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Signing Diagnostics")
        } footer: {
            Text("Run Verify P12 and Profile Match to check the local signing identity against the profile. Apple revocation status, device eligibility and an actual app-signing operation are not checked.")
        }
    }

    private func _diagnosticRow(
        _ title: String, passed: Bool, success: String, failure: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(passed ? Color.green : Color.orange)
            Text(title)
            Spacer(minLength: 8)
            Text(passed ? success : failure)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    private func _verifySigningIdentity(data: Certificate) {
        guard !_identityCheckRunning,
              let p12URL = Storage.shared.getFile(.certificate, from: cert)
        else { return }

        let password = cert.password ?? ""
        let embedded = data.DeveloperCertificates ?? []
        _identityCheck = nil
        _identityCheckRunning = true

        // PKCS#12 parsing can be expensive. Do not block SwiftUI rendering.
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ZagP12IdentityCheck.verify(
                    file: p12URL,
                    password: password,
                    embeddedCertificates: embedded
                )
            }.value
            _identityCheck = result
            _identityCheckRunning = false
        }
    }

    private func _profileType(_ data: Certificate) -> String {
        if data.ProvisionsAllDevices == true {
            return "In-House / Enterprise"
        }
        if data.Entitlements?["get-task-allow"]?.value as? Bool == true {
            return "Development"
        }
        if let devices = data.ProvisionedDevices, !devices.isEmpty {
            return "Ad Hoc Distribution"
        }
        return "Distribution / Other"
    }
}

// MARK: - Bundle identifier / provisioning profile compatibility
extension CertificatesInfoView {
    private func _appCompatibilitySection(data: Certificate) -> some View {
        let entitlement = data.Entitlements?["application-identifier"]?.value as? String
            ?? data.Entitlements?["com.apple.application-identifier"]?.value as? String
        let requestedID = _testBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let check = _checkBundleIdentifier(requestedID, allowed: entitlement, teams: data.TeamIdentifier)

        return Section {
            if let entitlement {
                LabeledContent("Allowed App Identifier") {
                    Text(entitlement)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
                .copyableText(entitlement)
            } else {
                LabeledContent("Allowed App Identifier", value: "Not available")
            }

            TextField("Enter an app bundle identifier", text: $_testBundleID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !requestedID.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: check.matches ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(check.matches ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title)
                            .font(.subheadline.weight(.semibold))
                        Text(check.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent("Platform", value: data.Platform.joined(separator: ", "))
            LabeledContent("Device Eligibility") {
                Text(_deviceScope(data))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("App Compatibility")
        } footer: {
            Text("Enter the final CFBundleIdentifier of the app you plan to sign. This checks only the provisioning profile’s App ID pattern and team prefix; it does not validate requested entitlements, registered device UDIDs or installability.")
        }
    }

    private func _deviceScope(_ data: Certificate) -> String {
        if data.ProvisionsAllDevices == true {
            return "All devices (in-house profile)"
        }
        if let devices = data.ProvisionedDevices {
            return "\(devices.count) registered device(s)"
        }
        return "No device list (distribution profile)"
    }

    private func _checkBundleIdentifier(
        _ requested: String, allowed: String?, teams: [String]
    ) -> (matches: Bool, title: String, explanation: String) {
        guard !requested.isEmpty else { return (false, "", "") }
        guard let allowed, !allowed.isEmpty else {
            return (false, "Cannot determine compatibility",
                    "This profile does not expose an application-identifier entitlement.")
        }

        // An Apple application-identifier entitlement starts with an App ID
        // prefix, normally the Team ID, followed by a period and bundle ID.
        guard let separator = allowed.firstIndex(of: ".") else {
            return (false, "Invalid profile App ID",
                    "The application-identifier entitlement has no team prefix.")
        }
        let prefix = String(allowed[..<separator])
        let pattern = String(allowed[allowed.index(after: separator)...])
        guard teams.contains(prefix) else {
            return (false, "Team prefix differs",
                    "The App ID prefix is not listed among this profile’s Team Identifiers.")
        }

        let matches: Bool
        if pattern == "*" {
            matches = true
        } else if pattern.hasSuffix("*") && pattern.filter({ $0 == "*" }).count == 1 {
            let start = String(pattern.dropLast())
            matches = requested.hasPrefix(start) && requested.count > start.count
        } else {
            matches = requested == pattern
        }

        return matches
            ? (true, "App ID matches", "This bundle identifier matches the profile’s App ID pattern.")
            : (false, "App ID does not match", "This bundle identifier is not permitted by the profile’s App ID pattern.")
    }
}

// MARK: - Device eligibility and profile entitlement overview
extension CertificatesInfoView {
    private func _deviceCompatibilitySection(data: Certificate) -> some View {
        let typedUDID = _testDeviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        let registered = data.ProvisionedDevices ?? []
        let isEnterprise = data.ProvisionsAllDevices == true
        let isRegistered = registered.contains { $0.caseInsensitiveCompare(typedUDID) == .orderedSame }
        let hasDeviceList = data.ProvisionedDevices != nil

        return Section {
            if isEnterprise {
                Label("All-device enterprise provisioning", systemImage: "checkmark.shield")
                    .foregroundStyle(Color.accentColor)
                Text("This profile declares ProvisionsAllDevices. Device registration is not required by the profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hasDeviceList {
                LabeledContent("Registered Devices", value: String(registered.count))
                TextField("Check a device UDID", text: $_testDeviceUDID)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.none)

                if !typedUDID.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isRegistered ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isRegistered ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isRegistered ? "Device is registered" : "Device is not listed")
                                .font(.subheadline.weight(.semibold))
                            Text(isRegistered
                                 ? "The entered UDID appears in this provisioning profile."
                                 : "The entered UDID is not among the devices embedded in this profile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Label("No registered-device list", systemImage: "info.circle")
                Text("This profile does not include ProvisionedDevices. This is normal for App Store distribution, but it does not establish direct-install eligibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Device Compatibility")
        } footer: {
            Text("UDID comparisons are performed locally and are not saved or sent anywhere. A matching UDID does not guarantee successful installation.")
        }
    }

    private func _entitlementDiagnosticsSection(data: Certificate) -> some View {
        let entitlements = data.Entitlements ?? [:]
        let taskAllow = entitlements["get-task-allow"]?.value as? Bool
        let pushEnvironment = entitlements["aps-environment"]?.value as? String
        let appGroups = _entitlementStrings(entitlements, key: "com.apple.security.application-groups")
        let keychainGroups = _entitlementStrings(entitlements, key: "keychain-access-groups")
        let associatedDomains = _entitlementStrings(entitlements, key: "com.apple.developer.associated-domains")
        let iCloudContainers = _entitlementStrings(entitlements, key: "com.apple.developer.icloud-container-identifiers")

        return Section {
            LabeledContent("Profile Entitlements", value: String(entitlements.count))
            LabeledContent("Debugging Allowed") {
                Text(taskAllow.map { $0 ? "Yes (development)" : "No" } ?? "Not specified")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Push Notifications") {
                Text(pushEnvironment ?? "Not included")
                    .foregroundStyle(.secondary)
            }
            _entitlementGroup("App Groups", values: appGroups)
            _entitlementGroup("Keychain Groups", values: keychainGroups)
            _entitlementGroup("Associated Domains", values: associatedDomains)
            _entitlementGroup("iCloud Containers", values: iCloudContainers)
        } header: {
            Text("Entitlement Capabilities")
        } footer: {
            Text("These capabilities come from the provisioning profile. Zag Store has not compared them with an app’s requested entitlements; a capability being listed does not guarantee it will work after signing.")
        }
    }

    private func _entitlementStrings(
        _ entitlements: [String: AnyCodable], key: String
    ) -> [String] {
        entitlements[key]?.value as? [String] ?? []
    }

    @ViewBuilder
    private func _entitlementGroup(_ title: String, values: [String]) -> some View {
        if values.isEmpty {
            LabeledContent(title, value: "Not included")
        } else {
            DisclosureGroup("\(title) (\(values.count))") {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .copyableText(value)
                }
            }
        }
    }
}

// MARK: - Requested entitlements vs profile (local, read-only)
extension CertificatesInfoView {
    private func _requestedEntitlementsSection(data: Certificate) -> some View {
        Section {
            Text("Paste the XML property-list entitlements extracted from the app you intend to sign.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $_requestedEntitlementsText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 180)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: _requestedEntitlementsText) { _ in
                    _entitlementCheck = nil
                }

            HStack {
                Button("Compare Entitlements") {
                    let profile = data.Entitlements?.mapValues { $0.value } ?? [:]
                    _entitlementCheck = ZagEntitlementCompatibility.compare(
                        requestedXML: _requestedEntitlementsText,
                        profile: profile
                    )
                }
                .disabled(_requestedEntitlementsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if !_requestedEntitlementsText.isEmpty {
                    Button("Clear") {
                        _requestedEntitlementsText = ""
                        _entitlementCheck = nil
                    }
                }
            }

            if let result = _entitlementCheck {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result.issues.isEmpty && result.error == nil
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.issues.isEmpty && result.error == nil ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.subheadline.weight(.semibold))
                        Text(result.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !result.issues.isEmpty {
                    ForEach(result.issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.circle")
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("Requested Entitlements Check")
        } footer: {
            Text("Only explicitly supplied app entitlements are compared. Values stay in memory on this page and are not uploaded or stored. Matching these checks does not prove the app will sign or install.")
        }
    }
}

enum ZagEntitlementCompatibility {
    struct Result {
        let checked: Int
        let issues: [String]
        let error: String?

        var title: String {
            if error != nil { return "Cannot compare entitlements" }
            return issues.isEmpty ? "No mismatches detected" : "Potential entitlement conflicts"
        }
        var summary: String {
            if let error { return error }
            return "\(checked) requested entitlement(s) checked; \(issues.count) potential conflict(s)."
        }
    }

    static func compare(requestedXML: String, profile: [String: Any]) -> Result {
        guard let bytes = requestedXML.data(using: .utf8),
              bytes.count <= 512_000 else {
            return Result(checked: 0, issues: [], error: "Entitlements input is too large or invalid.")
        }
        let decoded: Any
        do {
            decoded = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        } catch {
            return Result(checked: 0, issues: [], error: "Enter a valid XML property list containing a dictionary of entitlements.")
        }
        guard let requested = decoded as? [String: Any] else {
            return Result(checked: 0, issues: [], error: "The entitlement plist must contain a dictionary.")
        }

        var issues: [String] = []
        for key in requested.keys.sorted() {
            guard let requestedValue = requested[key] else { continue }
            guard let allowedValue = profile[key] else {
                issues.append("\(key): not included in profile")
                continue
            }
            if !matches(requestedValue, allowedValue) {
                issues.append("\(key): requested value differs from profile")
            }
        }
        return Result(checked: requested.count, issues: issues, error: nil)
    }

    private static func matches(_ requested: Any, _ allowed: Any) -> Bool {
        // App ID, keychain and group entitlements can include a trailing
        // wildcard. A wildcard is not a general-purpose glob expression.
        if let requested = requested as? String, let allowed = allowed as? String {
            if allowed == requested { return true }
            if allowed.hasSuffix("*"), allowed.filter({ $0 == "*" }).count == 1 {
                return requested.hasPrefix(String(allowed.dropLast()))
            }
            return false
        }
        if let requested = requested as? [String], let allowed = allowed as? [String] {
            return requested.allSatisfy { item in
                allowed.contains { matches(item, $0) }
            }
        }
        if let requested = requested as? [String: Any],
           let allowed = allowed as? [String: Any] {
            return requested.allSatisfy { key, value in
                guard let permitted = allowed[key] else { return false }
                return matches(value, permitted)
            }
        }
        if let lhs = requested as? NSNumber, let rhs = allowed as? NSNumber {
            return CFGetTypeID(lhs) == CFGetTypeID(rhs) && lhs == rhs
        }
        if let lhs = requested as? Data, let rhs = allowed as? Data {
            return lhs == rhs
        }
        if let lhs = requested as? Date, let rhs = allowed as? Date {
            return lhs == rhs
        }
        return false
    }
}

// MARK: - Paid certificate diagnostics (read-only)
extension CertificatesInfoView {
    private func _validitySection(data: Certificate) -> some View {
        let duration = data.ExpirationDate.timeIntervalSince(data.CreationDate)
        let elapsed = Date().timeIntervalSince(data.CreationDate)
        let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 1
        let remaining = max(0, Calendar.current.dateComponents(
            [.day], from: Date(), to: data.ExpirationDate
        ).day ?? 0)

        return Section {
            LabeledContent("Valid From") {
                Text(data.CreationDate, format: .dateTime.day().month(.abbreviated).year())
            }
            LabeledContent("Valid Until") {
                Text(data.ExpirationDate, format: .dateTime.day().month(.abbreviated).year())
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Profile Validity")
                    Spacer()
                    Text("\(Int(fraction * 100))% elapsed")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: fraction)
                    .tint(data.ExpirationDate <= Date() ? .red : .accentColor)
            }
            LabeledContent("Remaining Days") {
                Text("\(remaining)")
                    .foregroundStyle(data.ExpirationDate <= Date() ? .red : .secondary)
            }
        } header: {
            Text("Validity Period")
        } footer: {
            Text("These dates describe the provisioning profile, not necessarily the P12 signing certificate.")
        }
    }

    private func _identitySection(data: Certificate) -> some View {
        Section {
            LabeledContent("Team Name", value: data.TeamName)
            if let teamID = data.TeamIdentifier.first {
                LabeledContent("Team ID", value: teamID)
                    .copyableText(teamID)
            }
            LabeledContent("Profile UUID", value: data.UUID)
                .copyableText(data.UUID)
            LabeledContent("Profile Version", value: String(data.Version))
            LabeledContent("Signing Files") {
                Text(Storage.shared.getFile(.certificate, from: cert) != nil
                     ? "P12 present" : "P12 missing")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Signing Identity")
        } footer: {
            Text("File presence alone does not confirm that the private key, profile and certificate match.")
        }
    }

    private func _certificateFingerprints(data: Certificate) -> some View {
        Section {
            if let certificates = data.DeveloperCertificates, !certificates.isEmpty {
                ForEach(Array(certificates.enumerated()), id: \.offset) { index, certificate in
                    DisclosureGroup("Certificate \(index + 1)") {
                        let digest = SHA256.hash(data: certificate)
                        let fingerprint = digest.map { String(format: "%02X", $0) }
                            .joined(separator: ":")
                        LabeledContent("SHA-256 Fingerprint") {
                            Text(fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                        .copyableText(fingerprint)

                        if let subject = _x509Subject(certificate) {
                            LabeledContent("Subject", value: subject)
                        }
                    }
                }
            } else {
                Text("No embedded developer certificates available")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Developer Certificates")
        } footer: {
            Text("Fingerprints identify public certificates embedded in the provisioning profile. No private-key data is displayed.")
        }
    }

    // SecCertificateCopySubjectSummary is available on iOS; the macOS-only
    // SecCertificateCopyValues API must not be used in this iOS target.
    private func _x509Subject(_ der: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }
}

// MARK: - Extension: View
extension CertificatesInfoView {
	@ViewBuilder
	private func _infoSection(data: Certificate) -> some View {
        Section {
            _info(.localized("Name"), description: data.Name)
            _info(.localized("AppID Name"), description: data.AppIDName)
            _info(.localized("Team Name"), description: data.TeamName)
        } header: {
            Text("Profile Information")
        }
		
		Section {
			_info(.localized("Expires"), description: data.ExpirationDate.expirationInfo().formatted)
				.foregroundStyle(data.ExpirationDate.expirationInfo().color)
			
			_info("Revocation Status", description: cert.revoked ? "Marked revoked" : "Not verified")
			
			if let ppq = data.PPQCheck {
				_info(.localized("PPQCheck"), description: ppq ? "✓" : "✗")
			}
		}
	}
	
	@ViewBuilder
	private func _entitlementsSection(data: Certificate) -> some View {
		if let entitlements = data.Entitlements {
			Section {
				NavigationLink(.localized("View Entitlements")) {
					CertificatesInfoEntitlementView(entitlements: entitlements)
				}
			}
		}
	}
	
	@ViewBuilder
	private func _miscSection(data: Certificate) -> some View {
        Section {
            _disclosure(.localized("Platform"), keys: data.Platform)
			
			if let all = data.ProvisionsAllDevices {
				_info(.localized("Provision All Devices"), description: all.description)
			}
			
			if let devices = data.ProvisionedDevices {
				_disclosure(.localized("Provisioned Devices"), keys: devices)
			}
			
			_disclosure(.localized("Team Identifiers"), keys: data.TeamIdentifier)
			
			if let prefix = data.ApplicationIdentifierPrefix{
				_disclosure(.localized("Identifier Prefix"), keys: prefix)
			}
        } header: {
            Text("Additional Profile Data")
        }
	}
	
	@ViewBuilder
	private func _info(_ title: String, description: String) -> some View {
		LabeledContent(title) {
			Text(description)
		}
		.copyableText(description)
	}
	
	@ViewBuilder
	private func _disclosure(_ title: String, keys: [String]) -> some View {
		DisclosureGroup(title) {
			ForEach(keys, id: \.self) { key in
				Text(key)
					.foregroundStyle(.secondary)
					.copyableText(key)
			}
		}
	}
}

// MARK: - Local P12 identity / provisioning-profile comparison
// Deliberately performs no network or Apple Developer Portal requests.
// Never stores or displays the password, private key or PKCS#12 payload.
enum ZagP12IdentityCheck {
    enum Result: Sendable {
        case matched
        case missingFile
        case incorrectPassword
        case invalidArchive
        case missingIdentity
        case missingPrivateKey
        case mismatch

        var isMatch: Bool {
            if case .matched = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .matched: return "P12 and Profile Match"
            case .missingFile: return "P12 File Unavailable"
            case .incorrectPassword: return "P12 Password Rejected"
            case .invalidArchive: return "Unable to Read P12"
            case .missingIdentity: return "Signing Identity Missing"
            case .missingPrivateKey: return "Private Key Missing"
            case .mismatch: return "Certificate Mismatch"
            }
        }

        var explanation: String {
            switch self {
            case .matched:
                return "The P12 was unlocked, contains a private key and its public certificate is embedded in this provisioning profile. This does not establish Apple revocation or device eligibility."
            case .missingFile:
                return "The imported P12 file could not be read."
            case .incorrectPassword:
                return "The saved P12 password was rejected. Reimport the certificate with the correct password."
            case .invalidArchive:
                return "Security could not decode this P12 archive. It may be damaged or use unsupported encryption."
            case .missingIdentity:
                return "No signing identity was found in the P12 archive."
            case .missingPrivateKey:
                return "The P12 identity does not contain an accessible private key."
            case .mismatch:
                return "The P12 signing certificate is not among the developer certificates authorized by this provisioning profile."
            }
        }
    }

    static func verify(file: URL, password: String, embeddedCertificates: [Data]) -> Result {
        guard let archive = try? Data(contentsOf: file) else { return .missingFile }
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(archive as CFData, options, &imported)
        if status == errSecAuthFailed { return .incorrectPassword }
        guard status == errSecSuccess,
              let items = imported as? [[String: Any]]
        else { return .invalidArchive }

        // SecIdentity is a CoreFoundation type. Swift rejects a conditional
        // downcast from Any to SecIdentity; use an explicit type check first.
        guard let item = items.first(where: {
            CFGetTypeID($0[kSecImportItemIdentity as String] as CFTypeRef) == SecIdentityGetTypeID()
        }), let rawIdentity = item[kSecImportItemIdentity as String] else {
            return .missingIdentity
        }
        let identity = rawIdentity as! SecIdentity

        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              privateKey != nil else { return .missingPrivateKey }

        var publicCertificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &publicCertificate) == errSecSuccess,
              let publicCertificate
        else { return .missingIdentity }

        let signingDER = SecCertificateCopyData(publicCertificate) as Data
        return embeddedCertificates.contains(signingDER) ? .matched : .mismatch
    }
}

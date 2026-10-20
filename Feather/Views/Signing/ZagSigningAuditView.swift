//
//  ZagSigningAuditView.swift
//  Zag Store
//
//  On-demand, read-only audit of the selected signing configuration.
//  Does not mutate the signing engine or claim Apple acceptance.
//

import SwiftUI
import Foundation

struct ZagSigningAuditView: View {
    let app: AppInfoPresentable
    @ObservedObject var certificate: CertificatePair
    let options: Options

    @State private var identityResult: ZagP12IdentityCheck.Result?
    @State private var checkingIdentity = false
    @State private var auditGeneration = UUID()

    private enum Verdict {
        case passed, attention, unknown

        var symbol: String {
            switch self {
            case .passed: "checkmark.circle"
            case .attention: "exclamationmark.triangle"
            case .unknown: "questionmark.circle"
            }
        }

        var colour: Color {
            switch self {
            case .passed: .green
            case .attention: .orange
            case .unknown: .secondary
            }
        }
    }

    private struct Finding: Identifiable {
        let id: String
        let title: String
        let detail: String
        let verdict: Verdict
    }

    private var profile: Certificate? {
        Storage.shared.getProvisionFileDecoded(for: certificate)
    }

    private var finalIdentifier: String {
        let original = app.identifier ?? ""
        if options.ppqProtection && certificate.ppQCheck {
            // Mirrors SigningView._startSigning: PPQ can override the
            // user-selected identifier using the global PPQ suffix.
            return "\(original).\(OptionsManager.shared.options.ppqString)"
        }
        return options.appIdentifier ?? original
    }

    private var identifierWasOverridden: Bool {
        options.ppqProtection && certificate.ppQCheck
    }

    private var findings: [Finding] {
        guard let profile else {
            return [
                Finding(id: "profile", title: "Provisioning Profile",
                        detail: "Profile missing or unreadable", verdict: .attention)
            ]
        }

        let now = Date()
        let validDates = profile.CreationDate <= now && profile.ExpirationDate > now
        let hasP12 = Storage.shared.getFile(.certificate, from: certificate) != nil
        let pattern = profile.Entitlements?["application-identifier"]?.value as? String
            ?? profile.Entitlements?["com.apple.application-identifier"]?.value as? String
        let identifierMatches = Self._allows(finalIdentifier, pattern: pattern,
                                             teams: profile.TeamIdentifier)

        var checks: [Finding] = [
            Finding(id: "p12", title: "P12 File",
                    detail: hasP12 ? "File present" : "Missing P12 file",
                    verdict: hasP12 ? .passed : .attention),
            Finding(id: "dates", title: "Provisioning Dates",
                    detail: validDates
                        ? "Current until \(profile.ExpirationDate.formatted(date: .abbreviated, time: .omitted))"
                        : "Profile not currently valid",
                    verdict: validDates ? .passed : .attention),
            Finding(id: "revocation", title: "Recorded Revocation",
                    detail: certificate.revoked
                        ? "Previously marked revoked"
                        : "No local revocation recorded; Apple status not verified",
                    verdict: certificate.revoked ? .attention : .unknown),
            Finding(id: "identifier", title: "Final Requested App ID",
                    detail: finalIdentifier.isEmpty
                        ? "No bundle identifier available"
                        : identifierMatches
                            ? "\(finalIdentifier) matches the profile pattern"
                            : "\(finalIdentifier) does not match the profile pattern",
                    verdict: finalIdentifier.isEmpty || pattern == nil
                        ? .unknown : (identifierMatches ? .passed : .attention))
        ]

        if let file = options.appEntitlementsFile {
            let result = Self._customEntitlements(file, profile: profile)
            checks.append(Finding(
                id: "entitlements", title: "Custom Entitlements",
                detail: result.detail,
                verdict: result.verdict
            ))
        } else {
            checks.append(Finding(
                id: "entitlements", title: "Entitlements",
                detail: "No custom plist selected; signer-generated values not checked",
                verdict: .unknown
            ))
        }

        if let identityResult {
            checks.append(Finding(
                id: "identity", title: "P12 / Profile Identity",
                detail: identityResult.explanation,
                verdict: identityResult.isMatch ? .passed : .attention
            ))
        } else {
            checks.append(Finding(
                id: "identity", title: "P12 / Profile Identity",
                detail: checkingIdentity ? "Checking private-key identity…" : "Not yet verified",
                verdict: .unknown
            ))
        }

        return checks
    }

    var body: some View {
        let results = findings
        let issues = results.filter { if case .attention = $0.verdict { return true }; return false }.count
        let unknown = results.filter { if case .unknown = $0.verdict { return true }; return false }.count

        Form {
            Section {
                Label(
                    issues > 0 ? "\(issues) local issue(s) to review"
                        : unknown > 0 ? "No detected issues; some checks incomplete"
                        : "Local checks completed without detected issues",
                    systemImage: issues > 0 ? "exclamationmark.shield" : "checkmark.shield"
                )
                .foregroundStyle(issues > 0 ? Color.orange : Color.accentColor)

                LabeledContent("Application", value: app.name ?? "Unknown")
                LabeledContent("Certificate", value: certificate.nickname ?? profile?.Name ?? "Unknown")
                LabeledContent("Requested Identifier", value: finalIdentifier.isEmpty ? "Unavailable" : finalIdentifier)
                    .copyableText(finalIdentifier)

                if identifierWasOverridden {
                    Label("PPQ protection overrides the custom identifier when signing.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audit Summary")
            } footer: {
                Text("This is an advisory audit of the current signing settings. It does not sign the app or establish installation eligibility.")
            }

            Section {
                ForEach(results) { finding in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: finding.verdict.symbol)
                            .foregroundStyle(finding.verdict.colour)
                            .frame(width: 21)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(finding.title)
                                .font(.subheadline.weight(.medium))
                            Text(finding.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Local Checks")
            }

            Section {
                Button {
                    _verifyIdentity()
                } label: {
                    HStack(spacing: 10) {
                        if checkingIdentity {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark.shield")
                        }
                        Text(identityResult == nil ? "Verify P12 and Profile Match" : "Verify Identity Again")
                    }
                }
                .disabled(checkingIdentity || profile == nil ||
                          Storage.shared.getFile(.certificate, from: certificate) == nil)

                NavigationLink {
                    CertificatesInfoView(cert: certificate)
                } label: {
                    Label("Certificate Diagnostics", systemImage: "person.text.rectangle")
                }
            } header: {
                Text("Further Inspection")
            }

            Section {
                Label("Live Apple revocation and device acceptance", systemImage: "questionmark.circle")
                Label("Nested app, extension and framework signatures", systemImage: "questionmark.circle")
                Label("Final signed entitlements and output integrity", systemImage: "questionmark.circle")
                Label("Installation and launch on the target device", systemImage: "questionmark.circle")
            } header: {
                Text("Not Verified")
            } footer: {
                Text("Actual signing and installation remain separate operations. No private key, password or entitlement contents are sent over the network by this audit.")
            }
        }
        .navigationTitle("Signing Audit")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { _verifyIdentity() }
        .onDisappear { auditGeneration = UUID() }
    }

    private func _verifyIdentity() {
        guard !checkingIdentity,
              let profile,
              let p12 = Storage.shared.getFile(.certificate, from: certificate) else { return }

        let request = UUID()
        auditGeneration = request
        checkingIdentity = true
        identityResult = nil

        let password = certificate.password ?? ""
        let embedded = profile.DeveloperCertificates ?? []

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ZagP12IdentityCheck.verify(
                    file: p12, password: password, embeddedCertificates: embedded
                )
            }.value

            guard auditGeneration == request else { return }
            identityResult = result
            checkingIdentity = false
        }
    }

    private static func _allows(_ requested: String, pattern: String?, teams: [String]) -> Bool {
        guard !requested.isEmpty,
              let pattern,
              let separator = pattern.firstIndex(of: ".") else { return false }
        let prefix = String(pattern[..<separator])
        guard teams.contains(prefix) else { return false }
        let appPattern = String(pattern[pattern.index(after: separator)...])
        if appPattern == "*" { return true }
        if appPattern.hasSuffix("*") && appPattern.filter({ $0 == "*" }).count == 1 {
            let beginning = String(appPattern.dropLast())
            return requested.hasPrefix(beginning) && requested.count > beginning.count
        }
        return requested == appPattern
    }

    private static func _customEntitlements(
        _ url: URL, profile: Certificate
    ) -> (detail: String, verdict: Verdict) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey])).fileSize,
              size > 0 && size <= 512_000,
              let bytes = try? Data(contentsOf: url),
              let text = String(data: bytes, encoding: .utf8) else {
            return ("Custom entitlements unavailable or too large", .unknown)
        }
        let permitted = profile.Entitlements?.mapValues { $0.value } ?? [:]
        let comparison = ZagEntitlementCompatibility.compare(
            requestedXML: text, profile: permitted
        )
        if let error = comparison.error { return (error, .unknown) }
        if comparison.issues.isEmpty {
            return ("\(comparison.checked) requested keys checked; no basic conflicts found", .passed)
        }
        return ("\(comparison.issues.count) potential conflicts: \(comparison.issues.prefix(3).joined(separator: "; "))",
                .attention)
    }
}

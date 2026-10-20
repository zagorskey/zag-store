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
	
	var cert: CertificatePair
	
	// MARK: Body
	var body: some View {
		Form {
				Section {} header: {
					Image("Cert")
						.resizable()
						.scaledToFit()
						.frame(width: 107, height: 107)
						.frame(maxWidth: .infinity, alignment: .center)
				}
				
				if let data {
                    _diagnosticsSection(data: data)
                    _validitySection(data: data)
                    _identitySection(data: data)
                    _certificateFingerprints(data: data)
					_infoSection(data: data)
					_entitlementsSection(data: data)
					_miscSection(data: data)
				}
				
				Section {
					Button(.localized("Open in Files"), systemImage: "folder") {
						UIApplication.open(Storage.shared.getUuidDirectory(for: cert)!.toSharedDocumentsURL()!)
					}
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
		NBSection(.localized("Info")) {
			_info(.localized("Name"), description: data.Name)
			_info(.localized("AppID Name"), description: data.AppIDName)
			_info(.localized("Team Name"), description: data.TeamName)
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
		NBSection(.localized("Misc")) {
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
private enum ZagP12IdentityCheck {
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

        guard let identity = items.compactMap({
            $0[kSecImportItemIdentity as String] as? SecIdentity
        }).first else { return .missingIdentity }

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

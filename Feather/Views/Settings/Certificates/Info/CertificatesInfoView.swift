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
	
	var cert: CertificatePair
	
	// MARK: Body
	var body: some View {
		NBNavigationView(cert.nickname ?? "", displayMode: .inline) {
			Form {
				Section {} header: {
					Image("Cert")
						.resizable()
						.scaledToFit()
						.frame(width: 107, height: 107)
						.frame(maxWidth: .infinity, alignment: .center)
				}
				
				if let data {
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
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
		.onAppear {
			data = Storage.shared.getProvisionFileDecoded(for: cert)
		}
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

        return Section("Validity Period") {
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
        } footer: {
            Text("These dates describe the provisioning profile, not necessarily the P12 signing certificate.")
        }
    }

    private func _identitySection(data: Certificate) -> some View {
        Section("Signing Identity") {
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
        } footer: {
            Text("File presence alone does not confirm that the private key, profile and certificate match.")
        }
    }

    private func _certificateFingerprints(data: Certificate) -> some View {
        Section("Developer Certificates") {
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

                        if let summary = _x509Summary(certificate) {
                            LabeledContent("Subject", value: summary.subject)
                            LabeledContent("Valid From") {
                                Text(summary.validFrom, style: .date)
                            }
                            LabeledContent("Valid Until") {
                                Text(summary.validUntil, style: .date)
                            }
                        }
                    }
                }
            } else {
                Text("No embedded developer certificates available")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Fingerprints identify public certificates embedded in the provisioning profile. No private-key data is displayed.")
        }
    }

    private func _x509Summary(_ der: Data) -> (subject: String, validFrom: Date, validUntil: Date)? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(
                certificate,
                [kSecOIDX509V1SubjectName, kSecOIDX509V1ValidityNotBefore,
                 kSecOIDX509V1ValidityNotAfter] as CFArray,
                nil
              ) as? [String: Any],
              let subject = SecCertificateCopySubjectSummary(certificate) as String?
        else { return nil }
        func date(for key: CFString) -> Date? {
            guard let entry = values[key as String] as? [String: Any] else { return nil }
            return entry[kSecPropertyKeyValue as String] as? Date
        }
        guard let start = date(for: kSecOIDX509V1ValidityNotBefore),
              let end = date(for: kSecOIDX509V1ValidityNotAfter)
        else { return nil }
        return (subject, start, end)
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
			
			_info(.localized("Revoked"), description: cert.revoked ? "✓" : "✗")
			
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

//
//  CertificatesView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesView: View {
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	
	@State private var _isAddingPresenting = false
	@State private var _isRenamingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificatePair?
	@State private var _certToRename: CertificatePair?
	@State private var _newNickname: String = ""
	@State private var _pendingCertificateDelete: CertificatePair?

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	//
	private var _bindingSelectedCert: Binding<Int>?
	private var _selectedCertBinding: Binding<Int> {
		_bindingSelectedCert ?? $_storedSelectedCert
	}
	
	init(selectedCert: Binding<Int>? = nil) {
		self._bindingSelectedCert = selectedCert
	}
	
	// MARK: Body
	var body: some View {
		List {
            if let active = _activeCertificate {
                Section {
                    _activeCertificateCard(active)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Active Signing Certificate")
                }
            }

            Section {
			ForEach(Array(_certificates.enumerated()), id: \.element.uuid) { index, cert in
				_cellButton(for: cert, at: index)
					.listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
			}
            } header: {
                if !_certificates.isEmpty {
                    Text("Certificate Library (\(_certificates.count))")
                }
            }
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.navigationTitle(.localized("Certificates"))
		.overlay {
			if _certificates.isEmpty {
				if #available(iOS 17, *) {
					ContentUnavailableView {
						Label(.localized("No Certificates"), systemImage: "questionmark.folder.fill")
					} description: {
						Text(.localized("Get started signing by importing your first certificate."))
					} actions: {
						Button {
							_isAddingPresenting = true
						} label: {
							NBButton(.localized("Import"), style: .text)
						}
					}
				}
			}
		}
		.toolbar {
			if _bindingSelectedCert == nil {
				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing
				) {
					_isAddingPresenting = true
				}
			}
		}
		.sheet(item: $_isSelectedInfoPresenting) { cert in
			CertificatesInfoView(cert: cert)
		}
		.sheet(isPresented: $_isAddingPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
		}
		.alert(.localized("Change Name"), isPresented: $_isRenamingPresenting, presenting: _certToRename) { cert in
			TextField(.localized("Name"), text: $_newNickname)
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("OK")) {
				cert.nickname = _newNickname.isEmpty ? nil : _newNickname
				Storage.shared.saveContext()
			}
		}
		.alert(
			.localized("Delete Certificate?"),
			isPresented: Binding(
				get: { _pendingCertificateDelete != nil },
				set: { if !$0 { _pendingCertificateDelete = nil } }
			),
			presenting: _pendingCertificateDelete
		) { cert in
			Button(.localized("Delete"), role: .destructive) {
				Storage.shared.deleteCertificate(for: cert)
				_pendingCertificateDelete = nil
			}
			Button(.localized("Cancel"), role: .cancel) {
				_pendingCertificateDelete = nil
			}
		} message: { cert in
			Text(
				String(
					format: .localized("Delete %@ from Zag Store? This removes the certificate and its signing files."),
					cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("this certificate")
				)
			)
		}
	}
}

// MARK: - Certificate manager summary
extension CertificatesView {
    // Keep the existing selection index semantics for signing. This is a
    // read-only summary; changing the storage model belongs in a separate step.
    private var _activeCertificate: CertificatePair? {
        let index = _selectedCertBinding.wrappedValue
        guard _certificates.indices.contains(index) else { return nil }
        return _certificates[index]
    }

    private func _activeCertificateCard(_ cert: CertificatePair) -> some View {
        let profile = Storage.shared.getProvisionFileDecoded(for: cert)
        let hasP12 = Storage.shared.getFile(.certificate, from: cert) != nil
        let hasProfile = profile != nil
        let expiration = profile?.ExpirationDate ?? cert.expiration
        let isExpired = expiration.map { $0 <= Date() } ?? true
        let isRevoked = cert.revoked

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(isRevoked || isExpired ? Color.orange : Color.accentColor)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text(cert.nickname ?? profile?.Name ?? "Signing Certificate")
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(2)
                    Text(profile?.TeamName ?? "Unknown signing team")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let expiration {
                HStack {
                    Text("Provisioning Profile")
                    Spacer()
                    Text(expiration, style: .date)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            HStack(spacing: 6) {
                Image(systemName: isRevoked || isExpired || !hasP12 || !hasProfile
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(isRevoked ? "Marked revoked" :
                     isExpired ? "Expired" :
                     !hasP12 ? "Missing P12 file" :
                     !hasProfile ? "Missing provisioning profile" :
                     "Files present · Revocation unverified")
                    .lineLimit(2)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isRevoked || isExpired || !hasP12 || !hasProfile
                             ? Color.orange : Color.secondary)

            Button {
                _isSelectedInfoPresenting = cert
            } label: {
                HStack {
                    Text("View Certificate Details")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(uiColor: .quaternarySystemFill))
        )
    }
}

// MARK: - View extension
extension CertificatesView {
	@ViewBuilder
	private func _cellButton(for cert: CertificatePair, at index: Int) -> some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		Button {
			_selectedCertBinding.wrappedValue = index
		} label: {
			CertificatesCellView(
				cert: cert
			)
			.padding()
			.background(
				RoundedRectangle(cornerRadius: cornerRadius)
					.fill(Color(uiColor: .quaternarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(
						_selectedCertBinding.wrappedValue == index ? Color.accentColor : Color.clear,
						lineWidth: 2
					)
			)
			.contextMenu {
				_contextActions(for: cert)
				if cert.isDefault != true {
					Divider()
					_actions(for: cert)
				}
			}
			.transaction {
				$0.animation = nil
			}
		}
		.buttonStyle(.plain)
		.swipeActions(edge: .trailing) {
			Button(role: .destructive) {
				_pendingCertificateDelete = cert
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
		}
	}
	
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			_pendingCertificateDelete = cert
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			_isSelectedInfoPresenting = cert
		}
		Button(.localized("Change Name"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			_isRenamingPresenting = true
		}
		if cert.nickname != nil {
			Button(.localized("Remove Name"), systemImage: "minus.circle", role: .destructive) {
				cert.nickname = nil
				Storage.shared.saveContext()
			}
		}
		Divider()
		Button(.localized("Check Revokage"), systemImage: "person.text.rectangle") {
			Storage.shared.revokagedCertificate(for: cert)
		}
	}
}

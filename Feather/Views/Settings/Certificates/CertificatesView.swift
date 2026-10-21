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
    @AppStorage("Feather.userTintColor") private var _themeColorHex = "#0090FF"
    private var _themeTint: Color { Color(hex: _themeColorHex) }
	
	@State private var _isAddingPresenting = false
	@State private var _isRenamingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificatePair?
	@State private var _certToRename: CertificatePair?
    @State private var _certToExport: CertificatePair?
	@State private var _newNickname: String = ""
	@State private var _pendingCertificateDelete: CertificatePair?
    @State private var _searchText = ""
    @State private var _filter: LibraryFilter = .all

    private enum LibraryFilter: String, CaseIterable {
        case all = "All"
        case ready = "Files Ready"
        case attention = "Attention"
    }

    private func _attention(_ cert: CertificatePair) -> Bool {
        guard let profile = Storage.shared.getProvisionFileDecoded(for: cert) else { return true }
        let now = Date()
        let expiringSoon = profile.ExpirationDate > now
            && profile.ExpirationDate <= now.addingTimeInterval(30 * 24 * 60 * 60)
        return cert.revoked
            || Storage.shared.getFile(.certificate, from: cert) == nil
            || profile.CreationDate > now
            || profile.ExpirationDate <= now
            || expiringSoon
    }

    // Filter using the original fetched-results index: selection persists as an index.
    private var _visible: [(offset: Int, element: CertificatePair)] {
        Array(_certificates.enumerated()).filter { item in
            let profile = Storage.shared.getProvisionFileDecoded(for: item.element)
            let query = _searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchable = [item.element.nickname ?? "", profile?.Name ?? "",
                              profile?.TeamName ?? "", profile?.TeamIdentifier.joined(separator: " ") ?? ""]
            let matches = query.isEmpty || searchable.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
            let needsAttention = _attention(item.element)
            return matches && (_filter == .all || (_filter == .attention && needsAttention)
                               || (_filter == .ready && !needsAttention))
        }
    }

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
        // Use the same native top inset as the main Settings Form.
        Form {
            if !_certificates.isEmpty {
                Section {
                    _dashboard
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Certificate Overview")
                }
            }

            if let active = _activeCertificate {
                Section {
                    _activeCertificateCard(active)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Active Signing Identity")
                }
            }

            if !_certificates.isEmpty {
                Section {
                    if _certificates.count > 1 || !_searchText.isEmpty || _filter != .all {
                        _libraryControls
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    if _visible.isEmpty {
                        Text("No certificates match your search or filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(_visible, id: \.element.uuid) { item in
                            _cellButton(for: item.element, at: item.offset)
                                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    Text("Certificate Library (\(_certificates.count))")
                } footer: {
                    Text("Tap to select · Long-press to manage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !_certificates.isEmpty {
                Section {
                    NavigationLink {
                        ZagCertificateToolsView()
                    } label: {
                        Label {
                            Text("Certificate Health & Tools")
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(_themeTint)
                        }
                    }
                } header: {
                    Text("Certificate Utilities")
                }
            }
        }
        .tint(_themeTint)
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
        .task {
            await ZagCertificateExpiryNotifications.refresh()
        }
        .onChange(of: _certificates.count) { _ in
            Task { await ZagCertificateExpiryNotifications.refresh() }
        }
        .navigationDestination(isPresented: Binding(
            get: { _isSelectedInfoPresenting != nil },
            set: { if !$0 { _isSelectedInfoPresenting = nil } }
        )) {
            if let cert = _isSelectedInfoPresenting {
                CertificatesInfoView(cert: cert)
            }
        }
		.sheet(isPresented: $_isAddingPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
		}
        .sheet(item: $_certToExport) { cert in
            NavigationStack {
                ZagCertificateExportView(cert: cert)
            }
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
                let deletedIndex = _certificates.firstIndex(where: { $0.objectID == cert.objectID })
                let selectedIndex = _selectedCertBinding.wrappedValue
                Storage.shared.deleteCertificate(for: cert)
                if let deletedIndex {
                    if deletedIndex < selectedIndex {
                        _selectedCertBinding.wrappedValue = selectedIndex - 1
                    } else if deletedIndex == selectedIndex {
                        _selectedCertBinding.wrappedValue = 0
                    }
                }
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

// MARK: - Certificate dashboard
extension CertificatesView {
    private var _activeCertificate: CertificatePair? {
        let index = _selectedCertBinding.wrappedValue
        guard _certificates.indices.contains(index) else { return nil }
        return _certificates[index]
    }

    private var _dashboard: some View {
        let attentionCount = _certificates.filter { _attention($0) }.count
        let now = Date()
        let deadline = now.addingTimeInterval(30 * 24 * 60 * 60)
        let expiring = _certificates.filter { cert in
            guard let profile = Storage.shared.getProvisionFileDecoded(for: cert) else { return false }
            return profile.ExpirationDate > now && profile.ExpirationDate <= deadline
        }.count

        return HStack(spacing: 8) {
            _metric("\(_certificates.count)", title: "Stored", icon: "square.stack.3d.up", tint: _themeTint)
            _metric("\(attentionCount)", title: "Attention", icon: "exclamationmark.shield",
                    tint: attentionCount > 0 ? .orange : _themeTint)
            _metric("\(expiring)", title: "Expiring Soon", icon: "calendar.badge.clock",
                    tint: expiring > 0 ? .orange : _themeTint)
        }
    }

    private func _metric(_ value: String, title: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var _libraryControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search certificates or teams", text: $_searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !_searchText.isEmpty {
                    Button {
                        _searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Picker("Certificate Filter", selection: $_filter) {
                ForEach(LibraryFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func _activeCertificateCard(_ cert: CertificatePair) -> some View {
        let profile = Storage.shared.getProvisionFileDecoded(for: cert)
        let attention = _attention(cert)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(_themeTint)
                    .frame(width: 42, height: 42)
                    .background(_themeTint.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text("SELECTED FOR SIGNING")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(_themeTint)
                    Text(cert.nickname ?? profile?.Name ?? "Signing Certificate")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text(profile?.TeamName ?? "Unknown signing team")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            NavigationLink {
                ZagCertificateHealthView()
            } label: {
                HStack(spacing: 8) {
                    Label(_activeStatus(for: cert, profile: profile),
                          systemImage: attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(attention ? Color.orange : _themeTint)
                    Spacer(minLength: 4)
                    if let expiry = profile?.ExpirationDate {
                        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                        Text(days < 0 ? "Expired" : days == 0 ? "Expires today" : "\(days) days left")
                            .foregroundStyle(days <= 30 ? Color.orange : Color.secondary)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open certificate health and expiry reminders")

            Button {
                _isSelectedInfoPresenting = cert
            } label: {
                HStack {
                    Label("Inspect Certificate", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(_themeTint)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(_themeTint.opacity(0.18), lineWidth: 0.75)
                }
        }
    }

    private func _activeStatus(for cert: CertificatePair, profile: Certificate?) -> String {
        guard let profile else { return "Profile unavailable" }
        if cert.revoked { return "Marked revoked" }
        if Storage.shared.getFile(.certificate, from: cert) == nil { return "P12 missing" }
        let now = Date()
        if profile.CreationDate > now { return "Profile not yet valid" }
        if profile.ExpirationDate <= now { return "Profile expired" }
        if profile.ExpirationDate <= now.addingTimeInterval(30 * 24 * 60 * 60) {
            return "Expiring soon"
        }
        return "Files appear ready"
    }

}

// MARK: - View extension
extension CertificatesView {
	@ViewBuilder
	private func _cellButton(for cert: CertificatePair, at index: Int) -> some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				22.0
			} else {
				16.0
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
					.fill(Color(uiColor: .secondarySystemGroupedBackground))
			)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(
						_selectedCertBinding.wrappedValue == index ? _themeTint.opacity(0.55) : Color.primary.opacity(0.06),
						lineWidth: 1
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
        Button("Export Signing Files", systemImage: "square.and.arrow.up") {
            _certToExport = cert
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

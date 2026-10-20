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
        return cert.revoked
            || Storage.shared.getFile(.certificate, from: cert) == nil
            || profile.CreationDate > Date()
            || profile.ExpirationDate <= Date()
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
        List {
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
                }
            }

            if !_certificates.isEmpty {
                Section {
                    NavigationLink {
                        ZagProvisioningProfileInspectorView()
                    } label: {
                        Label("Inspect Provisioning Profile", systemImage: "doc.text.magnifyingglass")
                    }

                    NavigationLink {
                        ZagStoredProfileComparisonView()
                    } label: {
                        Label("Compare Stored Profiles", systemImage: "arrow.left.arrow.right")
                    }

                    NavigationLink {
                        ZagCertificateHealthView()
                    } label: {
                        Label("Certificate Health & Reminders", systemImage: "heart.text.square")
                    }
                } header: {
                    Text("Certificate Utilities")
                } footer: {
                    Text("Local inspection, comparison and optional expiry reminders.")
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

        return HStack(spacing: 9) {
            _metric("\(_certificates.count)", title: "Stored", icon: "square.stack.3d.up", tint: .accentColor)
            _metric("\(attentionCount)", title: "Attention", icon: "exclamationmark.shield",
                    tint: attentionCount > 0 ? .orange : .secondary)
            _metric("\(expiring)", title: "Expiring Soon", icon: "calendar.badge.clock",
                    tint: expiring > 0 ? .orange : .secondary)
        }
    }

    private func _metric(_ value: String, title: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text("SELECTED FOR SIGNING")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Color.accentColor)
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

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 8) {
                Label(attention ? "Needs attention" : "Files appear ready",
                      systemImage: attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(attention ? Color.orange : Color.green)
                Spacer(minLength: 4)
                if let expiry = profile?.ExpirationDate {
                    Text("Expires")
                        .foregroundStyle(.secondary)
                    Text(expiry, style: .date)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            Button {
                _isSelectedInfoPresenting = cert
            } label: {
                HStack {
                    Label("Inspect Certificate", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.75)
                }
        }
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
						_selectedCertBinding.wrappedValue == index ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
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

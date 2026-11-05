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
    @Environment(\.zagAccountClose) private var closeAccount
    @Environment(\.zagInsideAccountPopup) private var insideAccountPopup
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
    @State private var _dictationAvailable = false

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
        List {
            if !_certificates.isEmpty {
                Section {
                    _nonStickyTitle("Overview")
                    _dashboard
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if let active = _activeCertificate {
                Section {
                    _nonStickyTitle("Active Certificate")
                    _activeCertificateCard(active)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if !_certificates.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        Text("Certificates")
                        _certificateCountBadge(_certificates.count)
                    }
                    .modifier(ZagCertificateSectionTitleRow())
                    if _certificates.count > 1 || _filter != .all {
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
                }
            }

            if !_certificates.isEmpty {
                Section {
                    _nonStickyTitle("Utilities")
                    NavigationLink {
                        ZagCertificateToolsView()
                    } label: {
                        Label {
                            Text("Certificate Health & Tools")
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(_themeTint)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .modifier(ZagCertificatesTopInset())
        // Keep the UIKit search field pinned, with the same native search glyph
        // and microphone symbol configuration as Apps and Sources.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ZagCertificatesNativeBottomSearch(
                text: $_searchText,
                dictationAvailable: _dictationAvailable,
                startDictation: _startDictationFromSearchMic
            )
            .zagBottomSearchPlacement()
        }
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                if insideAccountPopup, let closeAccount {
                    Button(action: closeAccount) {
                        Image(systemName: "xmark")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Close")
                }
                if _bindingSelectedCert == nil {
                    Button {
                        _isAddingPresenting = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import Certificate")
                }
            }
		}
        .task {
            _probeSystemDictation()
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

    private func _nonStickyTitle(_ title: String) -> some View {
        Text(title)
            .modifier(ZagCertificateSectionTitleRow())
    }

    private var _positiveGreen: Color {
        Color(uiColor: UIColor(displayP3Red: 0.12, green: 0.83, blue: 0.34, alpha: 1))
    }

    private func _certificateCountBadge(_ count: Int) -> some View {
        Text(count.formatted())
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(_themeTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(_themeTint.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(_themeTint.opacity(0.5), lineWidth: 1)
            }
            .accessibilityLabel("\(count) certificates")
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
            _metric(_certificates.count, title: "Stored", icon: "square.stack.3d.up",
                    activeTint: _themeTint, numberTint: _positiveGreen)
            _metric(attentionCount, title: "Attention", icon: "exclamationmark.shield",
                    activeTint: .orange, numberTint: .orange)
            _metric(expiring, title: "Expiring Soon", icon: "calendar.badge.clock",
                    activeTint: .orange, numberTint: .orange)
        }
    }

    private func _metric(_ value: Int, title: String, icon: String,
                         activeTint: Color, numberTint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(value == 0 ? Color.secondary : activeTint)
                    .frame(width: 22, height: 25, alignment: .center)
                Text(value.formatted())
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? Color.primary : numberTint)
                    .frame(height: 25, alignment: .center)
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
        Picker("Certificate Filter", selection: $_filter) {
            ForEach(LibraryFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    private func _probeSystemDictation() {
        guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedInstance")),
              let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        else {
            _dictationAvailable = false
            return
        }
        _dictationAvailable = controller.responds(to: NSSelectorFromString("startDictation"))
    }

    private func _startDictationFromSearchMic() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            _startSystemDictation()
        }
    }

    private func _startSystemDictation() {
        guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedInstance")),
              let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        else { return }
        let preheat = NSSelectorFromString("preheatIfNecessary")
        if controller.responds(to: preheat) { _ = controller.perform(preheat) }
        let start = NSSelectorFromString("startDictation")
        if controller.responds(to: start) { _ = controller.perform(start) }
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(cert.nickname ?? profile?.Name ?? "Signing Certificate")
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(2)
                    Text("SN: \(profile?.Name ?? "Unavailable")")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(_themeTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
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
                    Image(systemName: attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(attention ? Color.red : _positiveGreen)
                        .frame(width: 24, alignment: .center)
                    Text(_activeStatus(for: cert, profile: profile))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if let expiry = profile?.ExpirationDate {
                        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                            Text(days < 0 ? "Expired" : days == 0 ? "0 days" : "\(days) days")
                                .monospacedDigit()
                        }
                        .foregroundStyle(days <= 30 || attention ? Color.red : _positiveGreen)
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
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 24, alignment: .center)
                    Text("Inspect Certificate")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
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

// Keep the custom plain-list cards and typography while reducing only the
// scroll-content top inset. Do not use Form here: it changes row presentation.
private struct ZagCertificatesTopInset: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentMargins(.top, 0, for: .scrollContent)
        } else {
            content
        }
    }
}



struct ZagCertificatesNativeBottomSearch: UIViewRepresentable {
    @Binding var text: String
    var prompt: String = "Search Certificates"
    let dictationAvailable: Bool
    let startDictation: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, startDictation: startDictation)
    }

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField(frame: .zero)
        field.placeholder = prompt
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.tintColor = .label
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        // Match the native Apps/Sources search placeholder styling.
        field.attributedPlaceholder = NSAttributedString(
            string: prompt,
            attributes: [
                .font: UIFont.systemFont(ofSize: 19, weight: .semibold),
                .foregroundColor: UIColor.placeholderText
            ]
        )
        // Override only the pinned field's leading search icon.
        // Apps and Sources continue to use their system-provided icons.
        let searchIcon = UIImageView(image: UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 22,
                weight: .regular,
                scale: .medium
            )
        ))
        searchIcon.tintColor = .label
        searchIcon.contentMode = .center
        searchIcon.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        field.leftView = searchIcon
        field.leftViewMode = .always
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)),
                        for: .editingChanged)

        let mic = ZagNativeSearchMicInstaller.makeMicrophoneButton(
            target: context.coordinator,
            action: #selector(Coordinator.dictate),
            pointSize: 22
        )
        field.rightView = mic
        field.rightViewMode = .always
        context.coordinator.field = field
        context.coordinator.mic = mic
        mic.isEnabled = dictationAvailable
        mic.alpha = dictationAvailable ? 1 : 0.45
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        if field.text != text { field.text = text }
        context.coordinator.startDictation = startDictation
        context.coordinator.mic?.isEnabled = dictationAvailable
        context.coordinator.mic?.alpha = dictationAvailable ? 1 : 0.45
    }

    final class Coordinator: NSObject {
        @Binding var text: String
        var startDictation: () -> Void
        weak var field: UISearchTextField?
        weak var mic: UIButton?

        init(text: Binding<String>, startDictation: @escaping () -> Void) {
            _text = text
            self.startDictation = startDictation
        }

        @objc func textChanged(_ field: UISearchTextField) {
            text = field.text ?? ""
        }

        @objc func dictate() {
            field?.becomeFirstResponder()
            startDictation()
        }
    }
}

private struct ZagCertificateSectionTitleRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.headline))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 22, leading: 20, bottom: 10, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}


// MARK: - Bottom search bar placement

/// Places a bottom search bar like iOS Settings: 48 points tall, 32 points
/// from each side and 28 points above the bottom of the screen (measured on
/// iOS 26 Settings). Shared by Settings and Certificates.
extension View {
    func zagBottomSearchPlacement() -> some View {
        modifier(ZagBottomSearchPlacement())
    }
}

private struct ZagBottomSearchPlacement: ViewModifier {
    static let height: CGFloat = 48
    static let sideInset: CGFloat = 32
    static let bottomGap: CGFloat = 28
    static let gapAboveKeyboard: CGFloat = 12

    // The bottom safe area below this bar: the home indicator area, or the
    // keyboard while it is up.
    @State private var safeBottom: CGFloat = 0

    func body(content: Content) -> some View {
        // Taller than any home indicator area: the keyboard is up, so keep
        // the bar above it rather than lowering it into it.
        let keyboardUp = safeBottom > 60
        return content
            .frame(height: Self.height)
            .zagSearchGlass()
            .padding(.horizontal, Self.sideInset)
            .padding(.top, 8)
            .padding(.bottom, keyboardUp ? Self.gapAboveKeyboard : max(0, Self.bottomGap - safeBottom))
            // The bar sits partly in the home indicator area, as in Settings.
            .offset(y: keyboardUp ? 0 : max(0, safeBottom - Self.bottomGap))
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { safeBottom = proxy.safeAreaInsets.bottom }
                    .onChange(of: proxy.safeAreaInsets.bottom) { safeBottom = $0 }
            })
    }
}

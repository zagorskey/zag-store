//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit
import Darwin
import IDeviceSwift

private enum ZagSettingsSection: String, CaseIterable, Identifiable {
	case display
	case certificates
	case features
	case diagnostics
	case health
	case refreshingApps
	case aboutUs
	case misc
	case reset

	var id: String { rawValue }

	var title: String {
		switch self {
		case .display: return "Display"
		case .certificates: return "Certificates"
		case .features: return "Features"
		case .diagnostics: return "Diagnostics"
		case .health: return "Health"
		case .refreshingApps: return "Refreshing Apps"
		case .aboutUs: return "About Us"
		case .misc: return "Browse"
		case .reset: return "Reset"
		}
	}
}

private let zagDefaultSettingsSectionOrder: [ZagSettingsSection] = [
	.display,
	.certificates,
	.features,
	.misc,
	.refreshingApps,
	.health,
	.diagnostics,
	.aboutUs
]

// MARK: - View
struct SettingsView: View {
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	@AppStorage(ZagCertificateSelection.askEveryTimeKey) private var _askCertificateEveryTime = false
	@AppStorage(ZagCertificateSelection.allowCustomisationKey) private var _allowSigningCustomisation = false
	@AppStorage(ZagBackgroundUpdateRefresh.enabledKey) private var _backgroundUpdatesEnabled = false
	@AppStorage(UpdateManager.updateNotificationsEnabledKey) private var _updateNotificationsEnabled = false
	@AppStorage(ZagBackgroundUpdateRefresh.automaticPreparationKey) private var _automaticUpdatePreparation = false
	@AppStorage(ZagBackgroundUpdateRefresh.automaticInstallationKey) private var _automaticUpdateInstallation = false
	@AppStorage("ZagStore.disableIdleTimeout") private var _disableIdleTimeout = false
	@State private var _currentIcon: String? = UIApplication.shared.alternateIconName
	@State private var _selectedCertificateInfo: CertificatePair?
	@State private var _pendingCertificateDelete: CertificatePair?
	@State private var _settingsSectionOrder = zagDefaultSettingsSectionOrder
	@State private var _isReorderingSettings = false
	@AppStorage("ZagStore.settingsSectionOrder") private var _storedSettingsSectionOrder = ""
	@AppStorage("ZagStore.settingsSectionSortMode") private var _settingsSectionSortMode = "default"
	@AppStorage("ZagStore.advancedSettingsUnlocked") private var _advancedSettingsUnlocked = false
	@State private var _showAdvancedSettingsWarning = false
	@State private var _settingsBackupURL: URL?
	@State private var _isSettingsImporterPresented = false
	@State private var _settingsBackupMessage: String?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	private var selectedCertificate: CertificatePair? {
		guard
			_storedSelectedCert >= 0,
			_storedSelectedCert < _certificates.count
		else {
			return nil
		}
		return _certificates[_storedSelectedCert]
	}

    
	private let _githubUrl = "https://github.com/claration/Feather"
    
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				if _isReorderingSettings {
					Section {
						ForEach(_settingsSectionOrder) { section in
							Text(section.title)
						}
						.onMove(perform: _moveSettingsSections)
					} header: {
						Text("Reorder Sections")
					}
				} else {
					ForEach(_settingsSectionOrder) { section in
						_settingsSection(section)
					}
					_settingsSection(.reset)
					if _advancedSettingsUnlocked {
						_advancedSettingsSections
					}
				}
			}
			.fileImporter(
				isPresented: $_isSettingsImporterPresented,
				allowedContentTypes: [.json, .data],
				allowsMultipleSelection: false
			) { result in
				_importSettingsBackup(result)
			}
			.sheet(item: $_settingsBackupURL) { url in
				ActivityView(activityItems: [url])
			}
			.alert(
				"Settings Backup",
				isPresented: Binding(
					get: { _settingsBackupMessage != nil },
					set: { if !$0 { _settingsBackupMessage = nil } }
				)
			) {
				Button("OK", role: .cancel) { _settingsBackupMessage = nil }
			} message: {
				Text(_settingsBackupMessage ?? "")
			}
			.safeAreaInset(edge: .bottom) {
				Color.clear.frame(height: 48)
			}
			.environment(\.editMode, .constant(_isReorderingSettings ? .active : .inactive))
			.onAppear {
				_loadSettingsSectionOrder()
			}
			.zagWallpaperSurface()
			.toolbar {
				ToolbarItemGroup(placement: .topBarLeading) {
					if _isReorderingSettings {
						Button {
							withAnimation(.snappy) {
								_isReorderingSettings = false
							}
						} label: {
							Image(systemName: "checkmark")
						}
						.accessibilityLabel("Done Reordering")
					} else {
						Menu {
							Button { _selectSettingsSectionOrder("default") } label: {
								Label("Default", systemImage: _settingsSectionSortMode == "default" ? "checkmark" : "ellipsis")
							}
							Button { _selectSettingsSectionOrder("custom") } label: {
								Label("Custom", systemImage: _settingsSectionSortMode == "custom" ? "checkmark" : "list.bullet")
							}
							Divider()
							Button { _beginSettingsSectionReordering() } label: {
								Label("Reorder", systemImage: "arrow.up.arrow.down")
							}
						} label: {
							Image(systemName: "slider.horizontal.3")
						}
						.accessibilityLabel("Settings Options")

						Button {
							if _advancedSettingsUnlocked {
								withAnimation(.snappy) {
									_advancedSettingsUnlocked = false
								}
								UIImpactFeedbackGenerator(style: .light).impactOccurred()
							} else {
								_presentAdvancedSettingsWarning()
							}
						} label: {
							Image(systemName: _advancedSettingsUnlocked ? "lock.open.fill" : "lock.fill")
						}
						.accessibilityLabel(_advancedSettingsUnlocked ? "Lock Advanced Settings" : "Unlock Advanced Settings")
					}
				}

				ToolbarItem(placement: .topBarTrailing) {
					Button {
						UIApplication.open("https://github.com/zagorskey/zag-store")
					} label: {
						Image(systemName: "chevron.left.forwardslash.chevron.right")
					}
					.accessibilityLabel("GitHub Repository")
				}
			}
		}
		.sheet(item: $_selectedCertificateInfo) { cert in
			CertificatesInfoView(cert: cert)
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

// MARK: - View extension
extension SettingsView {
	@ViewBuilder
	private var _advancedSettingsSections: some View {
		Section {
			EmptyView()
		} header: {
			Text("Developer Options")
		}

		Section {
			EmptyView()
		} header: {
			Text("Experimental Features")
		}
	}

	@ViewBuilder
	private func _settingsSection(_ section: ZagSettingsSection) -> some View {
		switch section {
		case .display:
			Section {
				NavigationLink(destination: AppearanceView()) {
					Label(.localized("Appearance"), systemImage: "circle.lefthalf.filled")
				}
				NavigationLink(destination: AppIconView(currentIcon: $_currentIcon)) {
					Label(.localized("App Icon"), systemImage: "app.badge")
				}
			} header: {
				Text("Display")
			}

		case .certificates:
			Section {
				NavigationLink(destination: CertificatesView()) {
					Label(.localized("Certificates"), systemImage: "checkmark.seal")
				}

				if let cert = selectedCertificate {
					VStack(alignment: .leading, spacing: 8) {
						CertificatesCellView(cert: cert)
						Divider().frame(maxWidth: .infinity)
					}
					.contentShape(Rectangle())
					.onTapGesture { _selectedCertificateInfo = cert }
					.listRowSeparator(.hidden)
					.swipeActions(edge: .trailing) {
						Button(role: .destructive) {
							_pendingCertificateDelete = cert
						} label: {
							Label(.localized("Delete"), systemImage: "trash")
						}
					}
				} else {
					Text(.localized("No Certificate"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}

				Toggle(.localized("Ask every time"), isOn: $_askCertificateEveryTime)
					.tint(.green)
				Toggle(.localized("Allow Customisation"), isOn: $_allowSigningCustomisation)
					.tint(.green)
			} header: {
				Text(.localized("Certificates"))
			} footer: {
				Text(.localized("Add and manage certificates used for signing apps."))
			}

		case .features:
			Section {
				NavigationLink(destination: InstallationView()) {
					Label(.localized("Installation"), systemImage: "arrow.down.circle")
				}
				NavigationLink(destination: ConfigurationView()) {
					Label(.localized("Signing Options"), systemImage: "signature")
				}
				NavigationLink(destination: ArchiveView()) {
					Label(.localized("Archive & Compression"), systemImage: "archivebox")
				}
			} header: {
				Text(.localized("Features"))
			} footer: {
				Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
			}

		case .diagnostics:
			Section {
				EmptyView()
			} header: {
				Text("Diagnostics")
			}

		case .health:
			Section {
				NavigationLink(destination: RPPairingDiagnosticsView()) {
					Label("Health Checks", systemImage: "stethoscope")
				}
			} header: {
				Text("Health")
			}

		case .refreshingApps:
			Section {
				Toggle(isOn: $_backgroundUpdatesEnabled) {
					Label("Background Updates", systemImage: "arrow.triangle.2.circlepath")
				}
				.onChange(of: _backgroundUpdatesEnabled) { _ in
					ZagBackgroundUpdateRefresh.shared.applySchedulingPreference()
				}

				Toggle(isOn: $_updateNotificationsEnabled) {
					Label("Update Notifications", systemImage: "bell.badge")
				}
				.onChange(of: _updateNotificationsEnabled) { enabled in
					guard enabled else { return }
					Task {
						let granted = await UpdateManager.shared.requestUpdateNotificationPermission()
						if !granted {
							await MainActor.run { _updateNotificationsEnabled = false }
						}
					}
				}

				Toggle(isOn: $_automaticUpdatePreparation) {
					Label("Automatic Preparation", systemImage: "shippingbox.and.arrow.backward")
				}
				.onChange(of: _automaticUpdatePreparation) { enabled in
					if !enabled { _automaticUpdateInstallation = false }
				}

				Toggle(isOn: $_automaticUpdateInstallation) {
					Label("Automatic Installation", systemImage: "square.and.arrow.down")
				}
				.disabled(!_automaticUpdatePreparation)

				Toggle(isOn: $_disableIdleTimeout) {
					Label("Disable Idle Timeout", systemImage: "sun.max")
				}
				.onChange(of: _disableIdleTimeout) { enabled in
					UIApplication.shared.isIdleTimerDisabled = enabled
				}
			} header: {
				Text("Refreshing Apps")
			} footer: {
				Text("Background Updates controls Zag Store’s scheduled checks. Automatic Preparation downloads and signs discovered updates. Automatic Installation attempts unattended installation when the RPPairing installation method and its direct transport are available. Update Notifications alerts you to newly discovered versions.")
			}

		case .aboutUs:
			_feedback()

		case .misc:
			_directories()

		case .reset:
			Section {
				NavigationLink(destination: ResetView()) {
					Label(.localized("Reset"), systemImage: "arrow.counterclockwise")
				}
			} header: {
				Text("Reset")
			}
		}
	}

	private func _selectSettingsSectionOrder(_ mode: String) {
		_settingsSectionSortMode = mode
		withAnimation(.snappy) {
			_settingsSectionOrder = mode == "default" ? zagDefaultSettingsSectionOrder : _storedCustomSettingsSectionOrder()
		}
	}

	private func _beginSettingsSectionReordering() {
		if _settingsSectionSortMode == "default" {
			_settingsSectionOrder = zagDefaultSettingsSectionOrder
		}
		_settingsSectionSortMode = "custom"
		_isReorderingSettings = true
	}

	private func _moveSettingsSections(from source: IndexSet, to destination: Int) {
		withAnimation(.snappy) {
			_settingsSectionOrder.move(fromOffsets: source, toOffset: destination)
		}
		_settingsSectionSortMode = "custom"
		_storedSettingsSectionOrder = _settingsSectionOrder.map(\.rawValue).joined(separator: ",")
	}

	private func _storedCustomSettingsSectionOrder() -> [ZagSettingsSection] {
		let stored = _storedSettingsSectionOrder
			.split(separator: ",")
			.compactMap { ZagSettingsSection(rawValue: String($0)) }
			.filter { $0 != .reset }
		let unique = stored.reduce(into: [ZagSettingsSection]()) { result, section in
			if !result.contains(section) { result.append(section) }
		}
		let missing = zagDefaultSettingsSectionOrder.filter { !unique.contains($0) }
		return unique.isEmpty ? zagDefaultSettingsSectionOrder : unique + missing
	}

	private func _loadSettingsSectionOrder() {
		_settingsSectionOrder = _settingsSectionSortMode == "custom"
			? _storedCustomSettingsSectionOrder()
			: zagDefaultSettingsSectionOrder
	}
	@ViewBuilder
	private func _feedback() -> some View {
		Section {
			NavigationLink(destination: AboutView()) {
				Label {
					Text("Zag Store")
				} icon: {
					FRAppIconView(size: 23)
				}
			}
            
			Button(.localized("Submit Feedback"), systemImage: "safari") {
				let bugAction: UIAlertAction = .init(title: .localized("Bug Report"), style: .default) { _ in
					UIApplication.open(_makeGitHubIssueURL(url: _githubUrl))
				}
				
				let chooseAction: UIAlertAction = .init(title: .localized("Other"), style: .default) { _ in
					UIApplication.open(URL(string: "\(_githubUrl)/issues/new/choose")!)
				}
				
				UIAlertController.showAlertWithCancel(
					title: .localized("Submit Feedback"),
					message: nil,
					actions: [bugAction, chooseAction]
				)
			}
		} header: {
			Text("About Us")
		} footer: {
			Text(.localized("If any issues occur within the app please report it via the GitHub repository. When submitting an issue, make sure to submit detailed information."))
		}
	}
    
	@ViewBuilder
	private func _directories() -> some View {
		Section {
			Button(.localized("Documents"), systemImage: "folder") {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			}
			Button(.localized("Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
			Button(.localized("Certificates"), systemImage: "folder") {
				UIApplication.open(FileManager.default.certificates.toSharedDocumentsURL()!)
			}

			Button("Export Settings", systemImage: "square.and.arrow.up") {
				do {
					_settingsBackupURL = try ZagSettingsBackup.exportURL()
				} catch {
					_settingsBackupMessage = error.localizedDescription
				}
			}

			Button("Import Settings", systemImage: "square.and.arrow.down") {
				_isSettingsImporterPresented = true
			}
		} header: {
			Text("Browse")
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
	}
    
	private func _importSettingsBackup(_ result: Result<[URL], Error>) {
		do {
			guard let url = try result.get().first else { return }
			let count = try ZagSettingsBackup.importSettings(from: url)
			_loadSettingsSectionOrder()
			_settingsBackupMessage = "Imported \(count) settings successfully. Some changes may require reopening their page to refresh."
		} catch {
			_settingsBackupMessage = error.localizedDescription
		}
	}

	private func _presentAdvancedSettingsWarning() {
		let alert = UIAlertController(
			title: "⚠︎  Advanced Settings",
			message: "Developer Options and Experimental Features are intended for advanced users. These settings may affect Zag Store’s behaviour and stability.",
			preferredStyle: .alert
		)

		let proceed = UIAlertAction(title: "Proceed", style: .default) { _ in
			UIImpactFeedbackGenerator(style: .light).impactOccurred()
			withAnimation(.snappy) {
				_advancedSettingsUnlocked = true
			}
		}
		proceed.setValue(UIColor.systemOrange, forKey: "titleTextColor")
		alert.addAction(proceed)
		alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
		guard
			let scene = UIApplication.shared.connectedScenes
				.compactMap({ $0 as? UIWindowScene })
				.first(where: { $0.activationState == .foregroundActive }),
			let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
		else {
			return
		}

		var presenter = root
		while let presented = presenter.presentedViewController {
			presenter = presented
		}
		presenter.present(alert, animated: true)
	}

	private func _makeGitHubIssueURL(url: String) -> String {
		var configurationSection = "### App Configuration:\n"
		
		switch UserDefaults.standard.integer(forKey: "Feather.installationMethod") {
		case 0: // Server
			let serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")
			let ipFix = UserDefaults.standard.bool(forKey: "Feather.ipFix")
			let serverType = (serverMethod == 0) ? "Fully Local" : "Semi Local"
			configurationSection += "- Install method: `Server`\n"
			configurationSection += "  - Server type: `\(serverType)`\n"
			configurationSection += "  - IP Fix: `\(ipFix)`\n"
		case 1: // idevice
			let pairingPath = HeartbeatManager.pairingFile()
			let pairingExists = FileManager.default.fileExists(atPath: pairingPath)
			let pairingStatus = pairingExists ? "`Present`" : "`Not Present`"
			configurationSection += "- Install method: `idevice`\n"
			configurationSection += "  - Pairing file: \(pairingStatus)\n"
		default:
			configurationSection += "- Install method: `Unknown`\n"
		}
        
		let body = """
		### Device Information
		- Device: `\(MobileGestalt().getStringForName("PhysicalHardwareNameString") ?? "Unknown")`
		- iOS Version: `\(UIDevice.current.systemVersion)`
		- App Version: `\(Bundle.main.version)`
		
		\(configurationSection)
		
		### Issue Description
		<!-- Describe your issue here -->
		
		### Steps to Reproduce
		1. 
		2. 
		3. 
		
		### Expected Behavior
		
		### Actual Behavior
		"""
		let encodedTitle = "[Bug] replace this with a descriptive title "
			.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
		let encodedBody = body
			.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
		return "\(url)/issues/new?template=bug.yml&title=\(encodedTitle)&text=\(encodedBody)"
	}
}

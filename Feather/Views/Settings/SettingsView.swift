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
                
				Section {
					NavigationLink(destination: CertificatesView()) {
						Label(.localized("Certificates"), systemImage: "checkmark.seal")
					}

					if let cert = selectedCertificate {
						VStack(alignment: .leading, spacing: 8) {
							Text(.localized("In Use"))
								.font(.headline)
								.foregroundStyle(.secondary)

							CertificatesCellView(cert: cert)

							Divider()
								.frame(maxWidth: .infinity)
						}
						.contentShape(Rectangle())
						.onTapGesture {
							_selectedCertificateInfo = cert
						}
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

					Toggle(
						.localized("Ask every time"),
						isOn: $_askCertificateEveryTime
					)
					.tint(.green)

					Toggle(
						.localized("Allow Customisation"),
						isOn: $_allowSigningCustomisation
					)
					.tint(.green)

				} header: {
					Text(.localized("Certificates"))
				} footer: {
					Text(.localized("Add and manage certificates used for signing apps."))
				}
                
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
					NavigationLink(destination: RPPairingDiagnosticsView()) {
						Label("Diagnostics & Health Checks", systemImage: "stethoscope")
					}
				} header: {
					Text(.localized("Features"))
				} footer: {
					Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
				}


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
								await MainActor.run {
									_updateNotificationsEnabled = false
								}
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
                

				_feedback()
				_directories()
                
				Section {
					NavigationLink(destination: ResetView()) {
						Label(.localized("Reset"), systemImage: "arrow.counterclockwise")
					}
				} footer: {
					Text(.localized("Reset the applications sources, certificates, apps, and general contents."))
				}
			}
			.zagWallpaperSurface()
			.toolbar {
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
			Button(.localized("Open Documents"), systemImage: "folder") {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Certificates"), systemImage: "folder") {
				UIApplication.open(FileManager.default.certificates.toSharedDocumentsURL()!)
			}
		} header: {
			Text(.localized("Misc"))
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
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

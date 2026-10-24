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
import NimbleJSON
import Photos


// Account navigation is already presented as a sheet; nested settings screens
// must not offer a second account sheet or duplicate the main VPN toolbar.
private struct ZagInsideAccountPopupKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var zagInsideAccountPopup: Bool {
        get { self[ZagInsideAccountPopupKey.self] }
        set { self[ZagInsideAccountPopupKey.self] = newValue }
    }
}

private struct ZagAccountCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var zagAccountClose: (() -> Void)? {
        get { self[ZagAccountCloseKey.self] }
        set { self[ZagAccountCloseKey.self] = newValue }
    }
}

// Shared avatar for pushed Settings destinations. Keep it on the destination
// (not the parent) so the native back button and existing actions remain intact.
private struct ZagSettingsDestinationAvatar: ViewModifier {
    @Environment(\.zagInsideAccountPopup) private var insideAccountPopup
    @Environment(\.zagAccountClose) private var closeAccount
    func body(content: Content) -> some View {
        content.toolbar {
            if !insideAccountPopup {
                ToolbarItem(placement: .principal) {
                    ZagLocalVPNToolbarStatus()
                }
                ToolbarItem(placement: .primaryAction) {
                    ZagProfileToolbarButton()
                        .tint(.primary)
                        .padding(.trailing, -2)
                }
            } else if let closeAccount {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: closeAccount) {
                        Image(systemName: "xmark")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

extension View {
    func zagSettingsDestinationAvatar() -> some View {
        modifier(ZagSettingsDestinationAvatar())
    }
}

private enum ZagSettingsSection: String, CaseIterable, Identifiable {
	case display
	case pages
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
		case .pages: return "Pages"
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
	.pages,
	.misc,
	.refreshingApps,
	.health,
	.diagnostics,
	.aboutUs
]

// Theme the switch track without recoloring navigation buttons or links.
struct ZagThemeTintToggleStyle: ToggleStyle {
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"

    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .tint(Color(hex: themeColorHex))
    }
}

// MARK: - View
struct SettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.zagAccountClose) private var closeAccount
	var embeddedInAccountNavigation = false
	var onAccountBack: (() -> Void)? = nil
	@AppStorage("Feather.userTintColor") private var userTintColor = "#0090FF"
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	@AppStorage(ZagPageStartupPolicy.rememberLastPageKey) private var _rememberLastPage = true
	@AppStorage(ZagPageStartupPolicy.defaultStartPageKey) private var _defaultStartPage = TabEnum.sources.rawValue
	@AppStorage("ZagStore.animatedSplashEnabled") private var _animatedSplashEnabled = true
	@AppStorage("ZagStore.splashSoundEnabled") private var _splashSoundEnabled = true
	@State private var _showSplashPreview = false
	@AppStorage(ZagCertificateSelection.askEveryTimeKey) private var _askCertificateEveryTime = false
	@AppStorage(ZagCertificateSelection.allowCustomisationKey) private var _allowSigningCustomisation = false
	@AppStorage(ZagBackgroundUpdateRefresh.enabledKey) private var _backgroundUpdatesEnabled = false
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
	@AppStorage("ZagStore.showInternalMetadata") private var _showInternalMetadata = false
	@State private var _showAdvancedSettingsWarning = false
	@State private var _photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
	@State private var _routeInstallation = false
	@State private var _routeInstallationDiagnostics = false
	@State private var _routeRPPairingDiagnostics = false
	@State private var _routeUpdateDiagnostics = false
    @State private var _settingsSearchText = ""
    @State private var _settingsDictationAvailable = false

    private var _settingsSearchQuery: String {
        _settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _settingsSearchMatches(_ terms: String) -> Bool {
        _settingsSearchQuery.isEmpty ||
        terms.localizedCaseInsensitiveContains(_settingsSearchQuery)
    }

    private func _probeSettingsDictation() {
        guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedInstance")),
              let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        else {
            _settingsDictationAvailable = false
            return
        }
        _settingsDictationAvailable = controller.responds(to: NSSelectorFromString("startDictation"))
    }

    private func _startSettingsDictation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
                  cls.responds(to: NSSelectorFromString("sharedInstance")),
                  let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
            else { return }
            let preheat = NSSelectorFromString("preheatIfNecessary")
            if controller.responds(to: preheat) { _ = controller.perform(preheat) }
            let start = NSSelectorFromString("startDictation")
            if controller.responds(to: start) { _ = controller.perform(start) }
        }
    }

	
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
    
	private var settingsContent: some View {
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
                    if !_settingsSearchQuery.isEmpty {
                        _settingsSearchResults
                    } else {
					ForEach(_settingsSectionOrder) { section in
						_settingsSection(section)
					}
					_backupAndRestoreSection
					_settingsSection(.reset)
					if _advancedSettingsUnlocked {
						_advancedSettingsSections
					}
                    }

					// MARK: Zag Store Running Build Footer
					Section {
						VStack(spacing: 5) {
							Text("Zag Store")
								.font(.footnote.weight(.semibold))
							Text(
								"Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") (Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"))"
							)
							.font(.caption)
							.monospacedDigit()
						}
						.frame(maxWidth: .infinity)
						.foregroundStyle(.secondary)
						.listRowBackground(Color.clear)
					}
				}
			}
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZagCertificatesNativeBottomSearch(
                    text: $_settingsSearchText,
                    prompt: "Search Settings",
                    dictationAvailable: _settingsDictationAvailable,
                    startDictation: _startSettingsDictation
                )
                .frame(height: 50)
                .zagSearchGlass()
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }

			.tint(Color(hex: userTintColor))
			.toggleStyle(ZagThemeTintToggleStyle())
			.environment(\.editMode, .constant(_isReorderingSettings ? .active : .inactive))
			.navigationDestination(isPresented: $_routeInstallation) {
				InstallationView().zagSettingsDestinationAvatar()
			}
			.navigationDestination(isPresented: $_routeInstallationDiagnostics) {
				ZagInstallationDiagnosticsView().zagSettingsDestinationAvatar()
			}
			.navigationDestination(isPresented: $_routeRPPairingDiagnostics) {
				RPPairingDiagnosticsView().zagSettingsDestinationAvatar()
			}
			.navigationDestination(isPresented: $_routeUpdateDiagnostics) {
				ZagUpdateDiagnosticsView().zagSettingsDestinationAvatar()
			}
			.onReceive(NotificationCenter.default.publisher(for: .zagStoreRouteRequested)) { note in
				guard let route = note.object as? ZagStoreRoute else { return }
				_handleZagStoreRoute(route)
			}
			.onAppear {
				_loadSettingsSectionOrder()
                _probeSettingsDictation()
				_refreshPhotoAuthorizationStatus()
				if let route = ZagStoreRouter.pendingRoute {
					_handleZagStoreRoute(route)
				}
			}
			.zagWallpaperSurface()
			.toolbar {
				if !embeddedInAccountNavigation {
					ToolbarItem(placement: .principal) {
						ZagLocalVPNToolbarStatus()
					}
				}
				ToolbarItemGroup(placement: .topBarLeading) {
					if embeddedInAccountNavigation {
						Button(action: { onAccountBack?() }) {
							Image(systemName: "chevron.left")
						}
						.accessibilityLabel("Back")
					}
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

						if !embeddedInAccountNavigation {
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
				}

				ToolbarItemGroup(placement: .topBarTrailing) {
					if embeddedInAccountNavigation {
						Button {
							if _advancedSettingsUnlocked {
								withAnimation(.snappy) { _advancedSettingsUnlocked = false }
								UIImpactFeedbackGenerator(style: .light).impactOccurred()
							} else {
								_presentAdvancedSettingsWarning()
							}
						} label: {
							Image(systemName: _advancedSettingsUnlocked ? "lock.open.fill" : "lock.fill")
						}
						.accessibilityLabel(_advancedSettingsUnlocked ? "Lock Advanced Settings" : "Unlock Advanced Settings")
						Button(action: { closeAccount?() }) {
							Image(systemName: "xmark")
						}
						.accessibilityLabel("Close")
					} else {
						Button {
							UIApplication.open("https://github.com/zagorskey/zag-store")
						} label: {
							Image(systemName: "chevron.left.forwardslash.chevron.right")
						}
						.accessibilityLabel("GitHub Repository")
						ZagProfileToolbarButton()
							.tint(.primary)
							.padding(.trailing, -2)
					}
				}
			}
		.navigationTitle("Settings")

	}

	// MARK: Body
	var body: some View {
		Group {
			if embeddedInAccountNavigation {
				settingsContent
			} else {
				NBNavigationView(.localized("Settings")) { settingsContent }
			}
		}
		.fullScreenCover(isPresented: $_showSplashPreview) {
			ZagCinematicSplashPreview()
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
	private func _handleZagStoreRoute(_ route: ZagStoreRoute) {
		guard route.tab == TabEnum.settings.rawValue else { return }

		_routeInstallation = false
		_routeInstallationDiagnostics = false
		_routeRPPairingDiagnostics = false
		_routeUpdateDiagnostics = false

		switch route {
		case .installation:
			_routeInstallation = true
		case .installationDiagnostics:
			_routeInstallationDiagnostics = true
		case .rppairingDiagnostics:
			_routeRPPairingDiagnostics = true
		case .updateDiagnostics:
			_routeUpdateDiagnostics = true
		case .settings:
			break
		default:
			return
		}

		ZagStoreRouter.consume(route)
	}

	@ViewBuilder
	private var _advancedSettingsSections: some View {
		Section {
			Toggle(isOn: $_showInternalMetadata) {
				Label("Show Internal Metadata", systemImage: "curlybraces")
			}
		} header: {
			Text("Developer Options")
		} footer: {
			Text("Developer controls expose additional Zag Store internals for testing and troubleshooting.")
		}

		Section {
			NavigationLink(destination: ZagSelfUpdateSignatureDiagnosticsView().zagSettingsDestinationAvatar()) {
                Label("Self-Update Signature Diagnostics", systemImage: "checkmark.shield")
            }
            NavigationLink(destination: ZagExperimentalSigningView().zagSettingsDestinationAvatar()) {
				Label("Signing", systemImage: "signature")
			}
		} header: {
			Text("Experimental Features")
		}

		Section {
			NavigationLink(destination: ZagLoggingSettingsView().zagSettingsDestinationAvatar()) {
				Label("Logging", systemImage: "doc.text.magnifyingglass")
			}
		} header: {
			Text("Logging")
		} footer: {
			Text("Detailed Zag Store runtime logging and log management will live here.")
		}
	}

    // Search covers the visible settings sections, their individual option names,
    // and advanced settings only when unlocked.
    private var _settingsSearchResults: some View {
        Group {
            ForEach(_settingsSectionOrder.filter { section in
                switch section {
                case .display:
                    return _settingsSearchMatches("Display Appearance App Icon")
                case .pages:
                    return _settingsSearchMatches("Pages Animated Splash Screen Splash Sound Mute Unmute Preview Splash Watch Replay Remember Last Page Default Start Page")
                case .certificates:
                    return _settingsSearchMatches("Certificates Active Certificate Ask every time Allow Customisation Signing")
                case .features:
                    return _settingsSearchMatches("Features Installation Signing Options Archive Compression Photos Access")
                case .diagnostics:
                    return _settingsSearchMatches("Diagnostics Installation Diagnostics Update Diagnostics Repo Performance Performance Loading Times Metrics")
                case .health:
                    return _settingsSearchMatches("Health Health Checks")
                case .refreshingApps:
                    return _settingsSearchMatches("Refreshing Apps Background Updates Automatic Preparation Automatic Installation Disable Idle Timeout")
                case .aboutUs:
                    return _settingsSearchMatches("About Us Zag Store Submit Feedback Bug Report")
                case .misc:
                    return _settingsSearchMatches("Browse Documents Archives Certificates Files")
                case .reset:
                    return _settingsSearchMatches("Reset")
                }
            }) { section in
                _settingsSection(section)
            }
            if _settingsSearchMatches("Backup Restore Backup Settings Restore Settings") {
                _backupAndRestoreSection
            }
            if _settingsSearchMatches("Reset") {
                _settingsSection(.reset)
            }
            if _advancedSettingsUnlocked &&
                _settingsSearchMatches("Developer Options Show Internal Metadata Experimental Features Self-Update Signature Diagnostics Signing Logging") {
                _advancedSettingsSections
            }
        }
    }

	@ViewBuilder
	private func _settingsSection(_ section: ZagSettingsSection) -> some View {
		switch section {
		case .display:
			Section {
				NavigationLink(destination: AppearanceView().zagSettingsDestinationAvatar()) {
					Label(.localized("Appearance"), systemImage: "circle.lefthalf.filled")
				}
				NavigationLink(destination: AppIconView(currentIcon: $_currentIcon).zagSettingsDestinationAvatar()) {
					Label(.localized("App Icon"), systemImage: "app.badge")
				}
			} header: {
				Text("Display")
			}

		case .pages:
			Section {
				Toggle(isOn: $_animatedSplashEnabled) {
					Label("Animated Splash Screen", systemImage: "sparkles.rectangle.stack")
				}
				Toggle(isOn: $_splashSoundEnabled) {
					Label("Splash Sound", systemImage: _splashSoundEnabled ? "speaker.wave.2" : "speaker.slash")
				}
				.disabled(!_animatedSplashEnabled)
				Button {
					_showSplashPreview = true
				} label: {
					Label("Preview Splash", systemImage: "play.rectangle")
				}
				.disabled(!ZagCinematicSplashView.available)
				Toggle(isOn: $_rememberLastPage) {
					Label("Remember Last Page", systemImage: "clock.arrow.circlepath")
				}

				Picker(selection: $_defaultStartPage) {
					ForEach(TabEnum.defaultTabs, id: \.rawValue) { tab in
						Text(tab.title).tag(tab.rawValue)
					}
				} label: {
					Label("Default Start Page", systemImage: "rectangle.portrait.and.arrow.right")
				}
				.disabled(_rememberLastPage)
			}
			header: {
				Text("Pages")
			}
			footer: {
				Text(
					_rememberLastPage
						? "Zag Store will reopen on the last main page you used."
						: "Choose which main page Zag Store opens on."
					+ " The cinematic splash plays on cold launches, or anytime using Preview Splash. Tap during playback to skip. Sound can be muted separately; the iPhone silent switch is respected."
				)
			}

		case .certificates:
			Section {
				NavigationLink(destination: CertificatesView().zagSettingsDestinationAvatar()) {
					Label {
                        Text(.localized("Certificates"))
                    } icon: {
                        Image(systemName: _certificates.isEmpty ? "checkmark.seal" : "checkmark.seal.fill")
                            .foregroundStyle(_certificates.isEmpty ? Color.primary : Color(uiColor: UIColor(displayP3Red: 0.12, green: 0.83, blue: 0.34, alpha: 1)))
                    }
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
				Toggle(.localized("Allow Customisation"), isOn: $_allowSigningCustomisation)
			} header: {
				Text(.localized("Certificates"))
			} footer: {
				Text(.localized("Add and manage certificates used for signing apps."))
			}

		case .features:
			Section {
				NavigationLink(destination: InstallationView().zagSettingsDestinationAvatar()) {
					Label(.localized("Installation"), systemImage: "arrow.down.circle")
				}
				NavigationLink(destination: ConfigurationView().zagSettingsDestinationAvatar()) {
					Label(.localized("Signing Options"), systemImage: "signature")
				}
				NavigationLink(destination: ArchiveView().zagSettingsDestinationAvatar()) {
					Label(.localized("Archive & Compression"), systemImage: "archivebox")
				}

				Button {
					_handlePhotosAccess()
				} label: {
					HStack {
						Label("Photos Access", systemImage: "photo.on.rectangle")
						Spacer()
						Text(_photoAuthorizationTitle)
							.foregroundStyle(.secondary)
					}
				}
				.buttonStyle(.plain)
			} header: {
				Text(.localized("Features"))
			} footer: {
				Text(.localized("Configure the apps way of installing, its zip compression levels, custom modifications to apps, and Photos library access."))
			}

		case .diagnostics:
			Section {
				NavigationLink(destination: ZagInstallationDiagnosticsView().zagSettingsDestinationAvatar()) {
					Label("Installation Diagnostics", systemImage: "arrow.down.app")
				}
				NavigationLink(destination: ZagUpdateDiagnosticsView().zagSettingsDestinationAvatar()) {
					Label("Update Diagnostics", systemImage: "waveform.path.ecg.rectangle")
				}
				NavigationLink(destination: ZagRepositoryPerformanceView().zagSettingsDestinationAvatar()) {
					Label("Repo Performance", systemImage: "speedometer")
				}
				NavigationLink(destination: ZagPerformanceDiagnosticsView().zagSettingsDestinationAvatar()) {
					Label("Performance", systemImage: "chart.xyaxis.line")
				}
			} header: {
				Text("Diagnostics")
			}

		case .health:
			Section {
				NavigationLink(destination: RPPairingDiagnosticsView().zagSettingsDestinationAvatar()) {
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
				Text("Background Updates controls Zag Store’s scheduled checks. Automatic Preparation downloads and signs discovered updates. Automatic Installation attempts unattended installation when the RPPairing installation method and its direct transport are available.")
			}

		case .aboutUs:
			_feedback()

		case .misc:
			_directories()

		case .reset:
			Section {
				NavigationLink(destination: ResetView().zagSettingsDestinationAvatar()) {
					Label(.localized("Reset"), systemImage: "arrow.counterclockwise")
				}
			} header: {
				Text("Reset")
			}
		}
	}

	private var _photoAuthorizationTitle: String {
		switch _photoAuthorizationStatus {
		case .authorized: return "Full Access"
		case .limited: return "Limited Access"
		case .denied: return "Denied"
		case .restricted: return "Restricted"
		case .notDetermined: return "Allow Access"
		@unknown default: return "Unknown"
		}
	}

	private func _refreshPhotoAuthorizationStatus() {
		_photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
	}

	private func _handlePhotosAccess() {
		switch _photoAuthorizationStatus {
		case .notDetermined:
			PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
				DispatchQueue.main.async {
					_photoAuthorizationStatus = status
				}
			}
		case .authorized, .limited, .denied, .restricted:
			guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
			UIApplication.shared.open(url)
		@unknown default:
			break
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
	private var _backupAndRestoreSection: some View {
		Section {
			NavigationLink(destination: ZagSettingsBackupView().zagSettingsDestinationAvatar()) {
				Label("Backup Settings", systemImage: "square.and.arrow.up")
			}
			NavigationLink(destination: ZagSettingsRestoreView().zagSettingsDestinationAvatar()) {
				Label("Restore Settings", systemImage: "square.and.arrow.down")
			}
		} header: {
			Text("Backup & Restore")
		}
	}

	@ViewBuilder
	private func _feedback() -> some View {
		Section {
			NavigationLink(destination: AboutView().zagSettingsDestinationAvatar()) {
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
		} header: {
			Text("Browse")
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
	}
    
	private func _presentAdvancedSettingsWarning() {
		let alert = UIAlertController(
			title: "Advanced Settings",
			message: "Developer Options and Experimental Features are intended for advanced users. These settings may affect Zag Store’s behaviour and stability.",
			preferredStyle: .alert
		)

		let warningAmber = UIColor(Color.orange)
		let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
		let titleParagraph = NSMutableParagraphStyle()
		titleParagraph.alignment = .center

		if let symbol = UIImage(
			systemName: "exclamationmark.triangle.fill",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
		) {
			let renderer = UIGraphicsImageRenderer(size: symbol.size)
			let renderedSymbol = renderer.image { _ in
				warningAmber.setFill()
				symbol.withRenderingMode(.alwaysTemplate).draw(
					in: CGRect(origin: .zero, size: symbol.size),
					blendMode: .normal,
					alpha: 1
				)
			}
			let attachment = NSTextAttachment()
			attachment.image = renderedSymbol.withRenderingMode(.alwaysOriginal)
			attachment.bounds = CGRect(x: 0, y: -3, width: 20, height: 20)
			let title = NSMutableAttributedString(attachment: attachment)
			title.append(NSAttributedString(
				string: "  Advanced Settings",
				attributes: [
					.font: titleFont,
					.foregroundColor: UIColor.label
				]
			))
			title.addAttribute(
				.paragraphStyle,
				value: titleParagraph,
				range: NSRange(location: 0, length: title.length)
			)
			alert.setValue(title, forKey: "attributedTitle")
		}

		let proceed = UIAlertAction(title: "Proceed", style: .default) { _ in
			UIImpactFeedbackGenerator(style: .light).impactOccurred()
			withAnimation(.snappy) {
				_advancedSettingsUnlocked = true
			}
		}
		proceed.setValue(warningAmber, forKey: "titleTextColor")
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




private struct ZagLoggingSettingsView: View {
	@AppStorage(ZagLogger.verboseKey) private var verboseLogging = false
	@ObservedObject private var pairingCore = ZagRPPairingCore.shared
	@State private var logSnapshot = ZagLogger.shared.snapshot()
	@State private var shareURL: URL?
	@State private var diagnosticReport: String?
	@State private var showCurrentProblems = false

	var body: some View {
		Form {
			Section {
				LabeledContent("Status", value: verboseLogging ? "Verbose" : "Standard")
				LabeledContent("Entries", value: "\(logSnapshot.entryCount)")
				LabeledContent("Log Size", value: ByteCountFormatter.string(fromByteCount: Int64(logSnapshot.byteCount), countStyle: .file))
				LabeledContent("Last Event", value: _lastEventText)
			} header: {
				Text("Overview")
			}

			Section {
				_currentSessionHealthCard
				NavigationLink(
					destination: ZagLogViewerView(launchMode: .currentProblems),
					isActive: $showCurrentProblems
				) {
					EmptyView()
				}
				.hidden()
			} header: {
				Text("Current Session")
			} footer: {
				Text("Session health reflects only events recorded since the latest Zag Store launch marker.")
			}

			Section {
				_activityLink("Sessions", count: logSnapshot.categoryCounts["Session", default: 0], mode: .sessions)
				_activityLink("Signing", count: logSnapshot.categoryCounts["Signing", default: 0] + logSnapshot.categoryCounts["Manual Signing", default: 0], mode: .signing)
				_activityLink("Installation", count: logSnapshot.categoryCounts["Installation", default: 0] + logSnapshot.categoryCounts["Repository Install", default: 0] + logSnapshot.categoryCounts["Repository Transaction", default: 0], mode: .installation)
				_activityLink("RPPairing", count: logSnapshot.categoryCounts["RPPairing", default: 0], mode: .rppairing)
				_activityLink("Updates", count: logSnapshot.categoryCounts["Updates", default: 0] + logSnapshot.categoryCounts["Notifications", default: 0], mode: .updates)
				_activityLink("Warnings & Errors", count: logSnapshot.warningCount + logSnapshot.errorCount, mode: .problems)
			} header: {
				Text("Activity")
			} footer: {
				Text("Counts reflect retained events. Tap a row to open the matching filtered log.")
			}

			Section {
				Toggle(isOn: $verboseLogging) {
					Label("Verbose Logging", systemImage: "text.alignleft")
				}
				.tint(.green)
			} footer: {
				Text("Records detailed Zag Store activity for troubleshooting. Warnings and errors are retained even when verbose logging is off. Logs are capped automatically to prevent unlimited storage growth.")
			}

			Section {
				if let keys = pairingCore.installedAppsDebugKeys, !keys.isEmpty {
					Text(keys)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)

					Button {
						UIPasteboard.general.string = keys
					} label: {
						Label("Copy Metadata Keys", systemImage: "doc.on.doc")
					}
				} else {
					Text("Refresh the Installed apps inventory first.")
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Installed App Metadata Keys")
			} footer: {
				Text("Temporary diagnostic showing the InstallationProxy metadata keys returned by iOS.")
			}

			Section {
				Button {
					_generateDiagnosticReport()
				} label: {
					Label("Generate Diagnostic Report", systemImage: "stethoscope")
				}

				NavigationLink(destination: ZagLogViewerView().zagSettingsDestinationAvatar()) {
					Label("View Logs", systemImage: "doc.text")
				}
				Button {
					UIPasteboard.general.string = ZagLogger.shared.read()
				} label: {
					Label("Copy Logs", systemImage: "doc.on.doc")
				}
				Button {
					shareURL = ZagLogger.shared.logURL
				} label: {
					Label("Export Logs", systemImage: "square.and.arrow.up")
				}
				Button(role: .destructive) {
					_presentClearLogsWarning()
				} label: {
					Label("Clear Logs", systemImage: "trash")
				}
			} header: {
				Text("Diagnostics & Logs")
			} footer: {
				Text("Diagnostic reports contain app, RPPairing, inventory, repository provenance summary and logs. Pairing records, certificate material and private keys are not included.")
			}
		}
		.navigationTitle("Logging")
		.zagWallpaperSurface()
		.onAppear(perform: _reloadMetrics)
		.onReceive(NotificationCenter.default.publisher(for: ZagLogger.didChangeNotification)) { _ in
			_reloadMetrics()
		}
		.onChange(of: verboseLogging) { enabled in
			ZagLogger.shared.info("Logging", "Verbose logging \(enabled ? "enabled" : "disabled")")
			_reloadMetrics()
		}
		.sheet(
			isPresented: Binding(
				get: { diagnosticReport != nil },
				set: { if !$0 { diagnosticReport = nil } }
			)
		) {
			if let diagnosticReport {
				ZagDiagnosticReportPreview(report: diagnosticReport)
			}
		}
		.sheet(
			isPresented: Binding(
				get: { shareURL != nil },
				set: { if !$0 { shareURL = nil } }
			)
		) {
			if let shareURL {
				ZagSettingsShareSheet(items: [shareURL])
			}
		}
	}


	private func _presentClearLogsWarning() {
		let alert = UIAlertController(
			title: "Clear Logs",
			message: "This permanently clears all retained Zag Store logs. This action cannot be undone.",
			preferredStyle: .alert
		)

		let destructiveRed = UIColor.systemRed
		let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
		let titleParagraph = NSMutableParagraphStyle()
		titleParagraph.alignment = .center

		if let symbol = UIImage(
			systemName: "exclamationmark.triangle.fill",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
		) {
			let renderer = UIGraphicsImageRenderer(size: symbol.size)
			let renderedSymbol = renderer.image { _ in
				destructiveRed.setFill()
				symbol.withRenderingMode(.alwaysTemplate).draw(
					in: CGRect(origin: .zero, size: symbol.size),
					blendMode: .normal,
					alpha: 1
				)
			}
			let attachment = NSTextAttachment()
			attachment.image = renderedSymbol.withRenderingMode(.alwaysOriginal)
			attachment.bounds = CGRect(x: 0, y: -3, width: 20, height: 20)
			let title = NSMutableAttributedString(attachment: attachment)
			title.append(NSAttributedString(
				string: "  Clear Logs",
				attributes: [
					.font: titleFont,
					.foregroundColor: UIColor.label
				]
			))
			title.addAttribute(
				.paragraphStyle,
				value: titleParagraph,
				range: NSRange(location: 0, length: title.length)
			)
			alert.setValue(title, forKey: "attributedTitle")
		}

		let clear = UIAlertAction(title: "Clear Logs", style: .destructive) { _ in
			ZagLogger.shared.clear()
			UINotificationFeedbackGenerator().notificationOccurred(.warning)
		}
		clear.setValue(destructiveRed, forKey: "titleTextColor")
		alert.addAction(clear)
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

	private var _currentSessionMetrics: (hasMarker: Bool, entries: Int, warnings: Int, errors: Int, startedAt: String) {
		let lines = logSnapshot.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
		guard let sessionIndex = lines.lastIndex(where: { $0.contains(" [Session] ") }) else {
			return (false, 0, 0, 0, "Unavailable")
		}
		let sessionLines = Array(lines[sessionIndex...])
		let warnings = sessionLines.filter { $0.contains(" [WARN] ") }.count
		let errors = sessionLines.filter { $0.contains(" [ERROR] ") }.count
		let timestamp = sessionLines.first?
			.split(separator: " ", maxSplits: 1)
			.first
			.map(String.init) ?? "Unknown"
		return (true, sessionLines.count, warnings, errors, _displayTimestamp(timestamp))
	}

	private var _currentSessionStatus: (title: String, icon: String, color: Color) {
		let metrics = _currentSessionMetrics
		guard metrics.hasMarker else {
			return ("No Session Marker", "questionmark.circle.fill", .secondary)
		}
		if metrics.errors > 0 {
			return ("Errors", "xmark.octagon.fill", .red)
		}
		if metrics.warnings > 0 {
			return ("Attention", "exclamationmark.triangle.fill", .orange)
		}
		return ("Healthy", "checkmark.circle.fill", .green)
	}

	@ViewBuilder
	private var _currentSessionHealthCard: some View {
		let metrics = _currentSessionMetrics
		let status = _currentSessionStatus
		VStack(alignment: .leading, spacing: 10) {
			Button {
				if metrics.warnings > 0 || metrics.errors > 0 {
					showCurrentProblems = true
				}
			} label: {
				HStack(spacing: 8) {
					Image(systemName: status.icon)
						.foregroundStyle(status.color)
					Text(status.title)
						.font(.headline)
						.foregroundStyle(.primary)
					Spacer()
					Text(metrics.startedAt)
						.font(.caption)
						.foregroundStyle(.secondary)
					if metrics.warnings > 0 || metrics.errors > 0 {
						Image(systemName: "chevron.right")
							.font(.caption.weight(.semibold))
							.foregroundStyle(.tertiary)
					}
				}
			}
			.buttonStyle(.plain)
			.disabled(metrics.warnings == 0 && metrics.errors == 0)

			HStack {
				_sessionMetric(title: "Events", value: metrics.entries)
				Spacer()
				_sessionProblemMetric(title: "Warnings", value: metrics.warnings)
				Spacer()
				_sessionProblemMetric(title: "Errors", value: metrics.errors)
			}
		}
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private func _sessionMetric(title: String, value: Int) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("\(value)")
				.font(.title3.weight(.semibold))
				.monospacedDigit()
			Text(title)
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private func _sessionProblemMetric(title: String, value: Int) -> some View {
		Button {
			if value > 0 {
				showCurrentProblems = true
			}
		} label: {
			_sessionMetric(title: title, value: value)
		}
		.buttonStyle(.plain)
		.disabled(value == 0)
	}

	private func _displayTimestamp(_ value: String) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		guard let date = formatter.date(from: value) else { return value }
		let output = DateFormatter()
		output.dateStyle = .none
		output.timeStyle = .short
		return output.string(from: date)
	}

	@ViewBuilder
	private func _activityLink(_ title: String, count: Int, mode: ZagLogViewerView.LaunchMode) -> some View {
		NavigationLink(destination: ZagLogViewerView(launchMode: mode).zagSettingsDestinationAvatar()) {
			HStack {
				Text(title)
				Spacer()
				Text("\(count)")
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
		}
		.disabled(count == 0)
	}

	private var _lastEventText: String {
		guard let date = logSnapshot.lastEventDate else { return "None" }
		let formatter = DateFormatter()
		formatter.dateStyle = .short
		formatter.timeStyle = .medium
		return formatter.string(from: date)
	}

	private func _reloadMetrics() {
		logSnapshot = ZagLogger.shared.snapshot()
	}

	private func _generateDiagnosticReport() {
		let defaults = UserDefaults.standard
		let repositoryOrigins = defaults.dictionary(forKey: "zagStore.repositoryOrigins") as? [String: String] ?? [:]
		let appOrigins = defaults.dictionary(forKey: "zagStore.repositoryAppOrigins") as? [String: String] ?? [:]
		let variantOrigins = defaults.dictionary(forKey: "zagStore.repositoryVariantOrigins") as? [String: String] ?? [:]
		let managedBundleIDs = defaults.array(forKey: "zagStore.managedInstalledBundleIDs") as? [String] ?? []
		let bundle = Bundle.main
		let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
		let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
		let snapshot = ZagLogger.shared.snapshot()

		let health = _healthSummary(snapshot: snapshot)
		let currentSession = _currentSessionSummary(snapshot: snapshot)
		let categorySummary = _categorySummary(snapshot: snapshot)
		let recentProblems = _recentProblems(snapshot: snapshot)
		let report = """
		Zag Store Diagnostic Report
		Generated: \(ISO8601DateFormatter().string(from: Date()))

		[Health Summary]
		Pairing: \(health.pairing)
		Inventory: \(health.inventory)
		Provenance: \(health.provenance)
		Retained Warnings / Errors: \(health.issueCount)

		[Current Session]
		Entries: \(currentSession.entryCount)
		Warnings: \(currentSession.warningCount)
		Errors: \(currentSession.errorCount)
		Started: \(currentSession.startedAt)

		[Activity by Category]
		\(categorySummary)

		[Recent Problems]
		\(recentProblems)

		[Application]
		Version: \(version)
		Build: \(build)
		Verbose Logging: \(verboseLogging ? "Enabled" : "Disabled")

		[RPPairing]
		Core Version: \(ZagRPPairingCore.version)
		Pairing File: \(pairingCore.pairingFileExists ? "Present" : "Missing")
		Pairing State: \(_pairingStateText)
		Gate2 State: \(_gate2StateText)
		Gate4 State: \(_gate4StateText)

		[Installed App Inventory]
		State: \(_inventoryStateText)
		Loaded Bundle IDs: \(pairingCore.installedBundleIDs.count)

		[Repository Provenance]
		Tracked Repositories: \(repositoryOrigins.count)
		Tracked App Identities: \(appOrigins.count)
		Tracked Variant Lineages: \(variantOrigins.count)
		Managed Installed Bundle IDs: \(managedBundleIDs.count)

		[Logging]
		Entries: \(snapshot.entryCount)
		Size: \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file))
		Last Event: \(_lastEventText)

		[Logs]
		\(snapshot.text.isEmpty ? "No log entries." : snapshot.text)
		"""

		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZagStoreDiagnostics", isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			let url = directory.appendingPathComponent("zag-store-diagnostic-report.txt")
			try report.write(to: url, atomically: true, encoding: .utf8)
			diagnosticReport = report
			ZagLogger.shared.info("Diagnostics", "Diagnostic report generated")
		} catch {
			ZagLogger.shared.error("Diagnostics", "Could not generate diagnostic report: \(error.localizedDescription)")
		}
	}

	private func _currentSessionSummary(snapshot: ZagLogger.Snapshot) -> (entryCount: Int, warningCount: Int, errorCount: Int, startedAt: String) {
		let lines = snapshot.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
		guard let sessionIndex = lines.lastIndex(where: { $0.contains(" [Session] ") }) else {
			let warnings = lines.filter { $0.contains(" [WARN] ") }.count
			let errors = lines.filter { $0.contains(" [ERROR] ") }.count
			return (lines.count, warnings, errors, "No session marker retained")
		}
		let sessionLines = Array(lines[sessionIndex...])
		let warnings = sessionLines.filter { $0.contains(" [WARN] ") }.count
		let errors = sessionLines.filter { $0.contains(" [ERROR] ") }.count
		let startedAt = sessionLines.first?
			.split(separator: " ", maxSplits: 1)
			.first
			.map(String.init) ?? "Unknown"
		return (sessionLines.count, warnings, errors, startedAt)
	}

	private func _categorySummary(snapshot: ZagLogger.Snapshot) -> String {
		guard !snapshot.categoryCounts.isEmpty else { return "No categorized events." }
		return snapshot.categoryCounts
			.sorted {
				if $0.value == $1.value { return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
				return $0.value > $1.value
			}
			.map { "\($0.key): \($0.value)" }
			.joined(separator: "\n")
	}

	private func _recentProblems(snapshot: ZagLogger.Snapshot) -> String {
		let problems = snapshot.text
			.split(separator: "\n", omittingEmptySubsequences: true)
			.map(String.init)
			.filter { $0.contains(" [WARN] ") || $0.contains(" [ERROR] ") }
			.suffix(10)
		guard !problems.isEmpty else { return "None." }
		return problems.joined(separator: "\n")
	}

	private func _healthSummary(snapshot: ZagLogger.Snapshot) -> (pairing: String, inventory: String, provenance: String, issueCount: Int) {
		let defaults = UserDefaults.standard
		let repositoryOrigins = defaults.dictionary(forKey: "zagStore.repositoryOrigins") as? [String: String] ?? [:]
		let variantOrigins = defaults.dictionary(forKey: "zagStore.repositoryVariantOrigins") as? [String: String] ?? [:]
		let issues = snapshot.warningCount + snapshot.errorCount

		let pairing: String
		if !pairingCore.pairingFileExists {
			pairing = "Pairing file missing"
		} else if case .failed(let message) = pairingCore.state {
			pairing = "Pairing failed: \(message)"
		} else {
			pairing = "Pairing file present"
		}

		let inventory: String
		switch pairingCore.installedAppsState {
		case .loaded(let count): inventory = "Loaded (\(count))"
		case .failed(let message): inventory = "Failed: \(message)"
		case .refreshing: inventory = "Refreshing"
		case .idle: inventory = "Not refreshed"
		}

		let provenance = "Repositories \(repositoryOrigins.count) • Variants \(variantOrigins.count)"
		return (pairing, inventory, provenance, issues)
	}

	private var _pairingStateText: String {
		switch pairingCore.state {
		case .idle: return "Idle"
		case .starting: return "Starting"
		case .advertising: return "Advertising"
		case .connected: return "Connected"
		case .pin: return "Awaiting PIN"
		case .paired: return "Paired"
		case .failed(let message): return "Failed: \(message)"
		}
	}

	private var _gate2StateText: String {
		switch pairingCore.gate2State {
		case .idle: return "Idle"
		case .starting: return "Starting"
		case .lockdown: return "Lockdown"
		case .pairing: return "Pairing"
		case .pairRecord: return "Pair Record"
		case .coreDevice: return "CoreDevice"
		case .rsd: return "RSD"
		case .deviceInfo: return "Device Info"
		case .installationProxy: return "Installation Proxy"
		case .installedApps: return "Installed Apps"
		case .afc: return "AFC"
		case .stagingWrite: return "Staging Write"
		case .stagingVerify: return "Staging Verify"
		case .complete: return "Complete"
		case .failed(let message): return "Failed: \(message)"
		}
	}

	private var _gate4StateText: String {
		switch pairingCore.gate4State {
		case .idle: return "Idle"
		case .starting: return "Starting"
		case .pairVerified: return "Pair Verified"
		case .tunnel: return "Tunnel"
		case .rsd: return "RSD"
		case .installing: return "Installing"
		case .uploading(let percent): return "Uploading \(percent)%"
		case .staged: return "IPA Staged"
		case .upgradeSubmitted: return "Upgrade Submitted"
		case .progress(let percent): return "Installing \(percent)%"
		case .complete: return "Complete"
		case .failed(let message): return "Failed: \(message)"
		}
	}

	private var _inventoryStateText: String {
		switch pairingCore.installedAppsState {
		case .idle: return "Idle"
		case .refreshing: return "Refreshing"
		case .loaded(let count): return "Loaded (\(count))"
		case .failed(let message): return "Failed: \(message)"
		}
	}
}

private struct ZagDiagnosticReportPreview: View {
	@Environment(\.dismiss) private var dismiss
	let report: String
	@State private var shareURL: URL?

	var body: some View {
		NavigationView {
			ScrollView {
				Text(report)
					.font(.system(size: 11, design: .monospaced))
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding()
			}
			.navigationTitle("Diagnostic Report")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Done") { dismiss() }
				}
				ToolbarItemGroup(placement: .topBarTrailing) {
					Button {
						UIPasteboard.general.string = report
					} label: {
						Image(systemName: "doc.on.doc")
					}
					Button {
						shareURL = _writeReport()
					} label: {
						Image(systemName: "square.and.arrow.up")
					}
				}
			}
		}
		.sheet(
			isPresented: Binding(
				get: { shareURL != nil },
				set: { if !$0 { shareURL = nil } }
			)
		) {
			if let shareURL {
				ZagSettingsShareSheet(items: [shareURL])
			}
		}
	}

	private func _writeReport() -> URL? {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZagStoreDiagnostics", isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			let url = directory.appendingPathComponent("zag-store-diagnostic-report.txt")
			try report.write(to: url, atomically: true, encoding: .utf8)
			return url
		} catch {
			ZagLogger.shared.error("Diagnostics", "Could not export diagnostic report: \(error.localizedDescription)")
			return nil
		}
	}
}

private struct ZagLogViewerView: View {
	enum LaunchMode {
		case all
		case currentProblems
		case sessions
		case signing
		case installation
		case rppairing
		case updates
		case problems
	}

	private enum Filter: String, CaseIterable, Identifiable {
		case all = "All"
		case currentSession = "Current Session"
		case currentProblems = "Current Problems"
		case sessions = "Sessions"
		case signing = "Signing"
		case installation = "Installation"
		case rppairing = "RPPairing"
		case updates = "Updates"
		case errors = "Errors"

		var id: String { rawValue }

		var icon: String {
			switch self {
			case .all: return "line.3.horizontal.decrease.circle"
			case .currentSession: return "play.circle.fill"
			case .currentProblems: return "exclamationmark.triangle.fill"
			case .sessions: return "clock.arrow.circlepath"
			case .signing: return "signature"
			case .installation: return "square.and.arrow.down"
			case .rppairing: return "link"
			case .updates: return "arrow.triangle.2.circlepath"
			case .errors: return "exclamationmark.octagon.fill"
			}
		}

		var tint: Color {
			switch self {
			case .currentProblems: return .orange
			case .errors: return .red
			case .currentSession: return .green
			default: return .accentColor
			}
		}
	}

	private struct Entry: Identifiable {
		let id = UUID()
		let raw: String
		let timestamp: String
		let level: String
		let category: String
		let message: String

		init(_ raw: String) {
			self.raw = raw
			let pattern = #"^(\\S+) \\[(DEBUG|INFO|WARN|ERROR)\\] \\[(.*?)\\] (.*)$"#
			if let expression = try? NSRegularExpression(pattern: pattern),
			   let match = expression.firstMatch(
				in: raw,
				range: NSRange(raw.startIndex..., in: raw)
			),
			   match.numberOfRanges == 5 {
				func value(_ index: Int) -> String {
					guard let range = Range(match.range(at: index), in: raw) else { return "" }
					return String(raw[range])
				}
				timestamp = value(1)
				level = value(2)
				category = value(3)
				message = value(4)
			} else {
				timestamp = ""
				level = "INFO"
				category = "Log"
				message = raw
			}
		}

		var shortTimestamp: String {
			guard !timestamp.isEmpty else { return "" }
			let formatter = ISO8601DateFormatter()
			formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			guard let date = formatter.date(from: timestamp) else { return timestamp }
			let output = DateFormatter()
			output.dateStyle = .none
			output.timeStyle = .medium
			return output.string(from: date)
		}

		var levelIcon: String {
			switch level {
			case "ERROR": return "xmark.octagon.fill"
			case "WARN": return "exclamationmark.triangle.fill"
			case "DEBUG": return "ladybug.fill"
			default: return "info.circle.fill"
			}
		}

		var levelColor: Color {
			switch level {
			case "ERROR": return .red
			case "WARN": return .orange
			case "DEBUG": return .secondary
			default: return .accentColor
			}
		}
	}

	@State private var logText = ""
	@State private var selectedFilter: Filter
	@State private var searchText = ""

	init(launchMode: LaunchMode = .all) {
		let filter: Filter
		switch launchMode {
		case .all: filter = .all
		case .currentProblems: filter = .currentProblems
		case .sessions: filter = .sessions
		case .signing: filter = .signing
		case .installation: filter = .installation
		case .rppairing: filter = .rppairing
		case .updates: filter = .updates
		case .problems: filter = .errors
		}
		_selectedFilter = State(initialValue: filter)
	}
	@State private var newestFirst = true
	@State private var filteredShareURL: URL?

	private var allEntries: [Entry] {
		logText
			.split(separator: "\n", omittingEmptySubsequences: true)
			.map { Entry(String($0)) }
	}

	private var currentSessionEntries: [Entry] {
		guard let sessionIndex = allEntries.lastIndex(where: { $0.category == "Session" }) else {
			return allEntries
		}
		return Array(allEntries[sessionIndex...])
	}

	private var filteredEntries: [Entry] {
		let sourceEntries = (selectedFilter == .currentSession || selectedFilter == .currentProblems)
			? currentSessionEntries
			: allEntries
		var entries = sourceEntries.filter { entry in
			switch selectedFilter {
			case .all, .currentSession:
				return true
			case .currentProblems:
				return entry.level == "ERROR" || entry.level == "WARN"
			case .sessions:
				return entry.category == "Session"
			case .signing:
				return entry.category == "Signing" || entry.category == "Manual Signing"
			case .installation:
				return entry.category == "Installation" || entry.category == "Repository Install" || entry.category == "Repository Transaction"
			case .rppairing:
				return entry.category == "RPPairing"
			case .updates:
				return entry.category == "Updates" || entry.category == "Notifications"
			case .errors:
				return entry.level == "ERROR" || entry.level == "WARN"
			}
		}

		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		if !query.isEmpty {
			entries = entries.filter { $0.raw.localizedCaseInsensitiveContains(query) }
		}
		return newestFirst ? entries.reversed() : entries
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(Filter.allCases) { filter in
						Button {
							selectedFilter = filter
						} label: {
							HStack(spacing: 5) {
								Image(systemName: filter.icon)
								Text(filter.rawValue)
							}
							.font(.caption.weight(.semibold))
							.padding(.horizontal, 12)
							.padding(.vertical, 7)
							.background(
								Capsule()
									.fill(selectedFilter == filter ? filter.tint : Color.secondary.opacity(0.14))
							)
							.foregroundStyle(selectedFilter == filter ? Color.white : filter.tint)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal)
				.padding(.vertical, 10)
			}

			Divider()

			HStack {
				Text("\(filteredEntries.count) of \(allEntries.count) entries")
					.font(.caption)
					.foregroundStyle(.secondary)
				if selectedFilter == .currentProblems || selectedFilter == .errors {
					Text("•")
						.font(.caption)
						.foregroundStyle(.secondary)
					Text(_problemSummary)
						.font(.caption.weight(.semibold))
						.foregroundStyle(selectedFilter == .currentProblems ? Color.orange : Color.red)
				}
				Spacer()
				Button {
					newestFirst.toggle()
				} label: {
					Label(
						newestFirst ? "Newest First" : "Oldest First",
						systemImage: newestFirst ? "arrow.down" : "arrow.up"
					)
					.font(.caption)
				}
				.buttonStyle(.plain)
			}
			.padding(.horizontal)
			.padding(.vertical, 8)

			Divider()

			ScrollView {
				if filteredEntries.isEmpty {
					_emptyState
				} else {
					LazyVStack(spacing: 8) {
						ForEach(filteredEntries) { entry in
							if entry.category == "Session" {
								_sessionView(entry)
							} else {
								_entryView(entry)
							}
						}
					}
					.padding()
				}
			}
		}
		.navigationTitle("Zag Store Logs")
		.toolbar {
			ToolbarItem(placement: .navigationBarTrailing) {
				Menu {
					Button {
						UIPasteboard.general.string = _filteredLogText
					} label: {
						Label("Copy Filtered Logs", systemImage: "doc.on.doc")
					}
					.disabled(filteredEntries.isEmpty)

					Button {
						filteredShareURL = _writeFilteredLogs()
					} label: {
						Label("Export Filtered Logs", systemImage: "square.and.arrow.up")
					}
					.disabled(filteredEntries.isEmpty)
				} label: {
					Image(systemName: "ellipsis.circle")
				}
			}
		}
		.searchable(text: $searchText, prompt: "Search logs")
		.zagWallpaperSurface()
		.onAppear(perform: _reload)
		.onReceive(NotificationCenter.default.publisher(for: ZagLogger.didChangeNotification)) { _ in
			_reload()
		}
		.sheet(
			isPresented: Binding(
				get: { filteredShareURL != nil },
				set: { if !$0 { filteredShareURL = nil } }
			)
		) {
			if let filteredShareURL {
				ZagSettingsShareSheet(items: [filteredShareURL])
			}
		}
	}

	@ViewBuilder
	private func _sessionView(_ entry: Entry) -> some View {
		HStack(spacing: 8) {
			Rectangle()
				.fill(Color.secondary.opacity(0.25))
				.frame(height: 1)
			Image(systemName: "play.circle.fill")
				.font(.caption)
				.foregroundStyle(.secondary)
			Text("Session Started")
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
			if !entry.shortTimestamp.isEmpty {
				Text(entry.shortTimestamp)
					.font(.caption2.monospacedDigit())
					.foregroundStyle(.secondary)
			}
			Rectangle()
				.fill(Color.secondary.opacity(0.25))
				.frame(height: 1)
		}
		.padding(.vertical, 4)
		.contextMenu {
			Button {
				UIPasteboard.general.string = entry.raw
			} label: {
				Label("Copy Session Marker", systemImage: "doc.on.doc")
			}
		}
	}

	@ViewBuilder
	private func _entryView(_ entry: Entry) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 6) {
				Image(systemName: entry.levelIcon)
					.font(.caption)
					.foregroundStyle(entry.levelColor)

				Text(entry.category)
					.font(.caption2.weight(.semibold))
					.padding(.horizontal, 7)
					.padding(.vertical, 3)
					.background(Capsule().fill(Color.secondary.opacity(0.13)))

				Spacer()

				Text(entry.shortTimestamp)
					.font(.caption2.monospacedDigit())
					.foregroundStyle(.secondary)
			}

			Text(entry.message)
				.font(.system(size: 12, design: .monospaced))
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(10)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Color.secondary.opacity(0.08))
		)
		.overlay(alignment: .leading) {
			RoundedRectangle(cornerRadius: 2)
				.fill(entry.levelColor)
				.frame(width: 3)
				.padding(.vertical, 8)
		}
		.contentShape(Rectangle())
		.contextMenu {
			Button {
				UIPasteboard.general.string = entry.raw
			} label: {
				Label("Copy Entry", systemImage: "doc.on.doc")
			}
			Button {
				UIPasteboard.general.string = entry.message
			} label: {
				Label("Copy Message", systemImage: "text.quote")
			}
		}
	}

	private var _emptyState: some View {
		VStack(spacing: 10) {
			Image(systemName: searchText.isEmpty ? "doc.text" : "magnifyingglass")
				.font(.system(size: 30))
				.foregroundStyle(.secondary)
			Text(searchText.isEmpty ? "No Log Entries" : "No Matches")
				.font(.headline)
			Text(searchText.isEmpty ? "No entries match this category." : "Try a different search or category.")
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal)
		.padding(.top, 50)
	}

	private var _problemSummary: String {
		let warnings = filteredEntries.filter { $0.level == "WARN" }.count
		let errors = filteredEntries.filter { $0.level == "ERROR" }.count
		return "\(warnings) warning\(warnings == 1 ? "" : "s") • \(errors) error\(errors == 1 ? "" : "s")"
	}

	private var _filteredLogText: String {
		filteredEntries.map(\.raw).joined(separator: "\n") + (filteredEntries.isEmpty ? "" : "\n")
	}

	private func _writeFilteredLogs() -> URL? {
		let safeFilter = selectedFilter.rawValue
			.lowercased()
			.replacingOccurrences(of: " ", with: "-")
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("zag-store-\(safeFilter)-logs.txt")
		do {
			try _filteredLogText.write(to: url, atomically: true, encoding: .utf8)
			return url
		} catch {
			ZagLogger.shared.error("Logging", "Failed to export filtered logs: \(error.localizedDescription)")
			return nil
		}
	}

	private func _reload() {
		logText = ZagLogger.shared.read()
	}
}

private struct ZagExperimentalSigningView: View {
	@StateObject private var optionsManager = OptionsManager.shared

	var body: some View {
		Form {
			Section {
				Toggle(isOn: $optionsManager.options.experiment_replaceSubstrateWithEllekit) {
					Label("Replace Substrate with ElleKit", systemImage: "pencil")
				}
				Toggle(isOn: $optionsManager.options.experiment_supportLiquidGlass) {
					Label("Enable Liquid Glass", systemImage: "26.circle")
				}
			} footer: {
				Text("These experimental transformations modify apps while signing. Replace Substrate with ElleKit attempts to redirect injected tweaks that depend on CydiaSubstrate to ElleKit. Enable Liquid Glass attempts to make compatible apps use the newer Liquid Glass appearance. Compatibility varies by app and injected tweak.")
			}
		}
		.navigationTitle("Signing")
		.zagWallpaperSurface()
		.onChange(of: optionsManager.options) { _ in
			optionsManager.saveOptions()
		}
	}
}


private struct ZagSettingsBackupView: View {
	@State private var backupURL: URL?
	@State private var message: String?

	var body: some View {
		Form {
			Section {
				Button("Export All Settings", systemImage: "square.and.arrow.up") {
					do {
						backupURL = try ZagSettingsBackup.exportURL()
					} catch {
						message = error.localizedDescription
					}
				}
			} footer: {
				Text("Exports all Zag Store settings. Certificates, private keys, pairing data, installed apps and caches are not included.")
			}
		}
		.navigationTitle("Backup Settings")
		.zagWallpaperSurface()
		.sheet(
			isPresented: Binding(
				get: { backupURL != nil },
				set: { if !$0 { backupURL = nil } }
			)
		) {
			if let url = backupURL {
				ZagSettingsShareSheet(items: [url])
			}
		}
		.alert(
			"Settings Backup",
			isPresented: Binding(
				get: { message != nil },
				set: { if !$0 { message = nil } }
			)
		) {
			Button("OK", role: .cancel) { message = nil }
		} message: {
			Text(message ?? "")
		}
	}
}

private struct ZagSettingsRestoreView: View {
	@State private var isImporterPresented = false
	@State private var message: String?

	var body: some View {
		Form {
			Section {
				Button("Import All Settings", systemImage: "square.and.arrow.down") {
					isImporterPresented = true
				}
			} footer: {
				Text("Restores all settings contained in a Zag Store settings backup.")
			}
		}
		.navigationTitle("Restore Settings")
		.zagWallpaperSurface()
		.fileImporter(
			isPresented: $isImporterPresented,
			allowedContentTypes: [.json, .data],
			allowsMultipleSelection: false
		) { result in
			importBackup(result)
		}
		.alert(
			"Settings Restore",
			isPresented: Binding(
				get: { message != nil },
				set: { if !$0 { message = nil } }
			)
		) {
			Button("OK", role: .cancel) { message = nil }
		} message: {
			Text(message ?? "")
		}
	}

	private func importBackup(_ result: Result<[URL], Error>) {
		do {
			guard let url = try result.get().first else { return }
			let count = try ZagSettingsBackup.importSettings(from: url)
			message = "Imported \(count) settings successfully. Some changes may require reopening their page to refresh."
		} catch {
			message = error.localizedDescription
		}
	}
}

private struct ZagSettingsShareSheet: UIViewControllerRepresentable {
	let items: [Any]

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: items, applicationActivities: nil)
	}

	func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


private struct ZagUpdateDiagnosticsView: View {
	@ObservedObject private var updateManager = UpdateManager.shared
	@State private var copied = false

	private var diagnosticLineCount: Int {
		updateManager.diagnosticsReport
			.split(separator: "\n", omittingEmptySubsequences: false)
			.count
	}

	var body: some View {
		Form {

			Section {
				NavigationLink(destination: ZagUpdateDiagnosticsReportView().zagSettingsDestinationAvatar()) {
					HStack {
						Label("View Full Report", systemImage: "doc.text.magnifyingglass")
						Spacer()
						Text("\(diagnosticLineCount) lines")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			} header: {
				Text("Latest Repository Refresh")
			} footer: {
				Text("Open the full report when needed. Refresh repositories first so the snapshot reflects the current installed apps and repository candidates.")
			}

			Section {
				Button {
					UIPasteboard.general.string = updateManager.diagnosticsReport
					copied = true
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
				} label: {
					Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
				}
			}
		}
		.navigationTitle("Update Diagnostics")
		.zagWallpaperSurface()
	}
}

private struct ZagUpdateDiagnosticsReportView: View {
	@ObservedObject private var updateManager = UpdateManager.shared
	@State private var copied = false

	var body: some View {
		ScrollView(.vertical, showsIndicators: true) {
			Text(updateManager.diagnosticsReport)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.navigationTitle("Diagnostics Report")
		.navigationBarTitleDisplayMode(.inline)
		.zagWallpaperSurface()
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					UIPasteboard.general.string = updateManager.diagnosticsReport
					copied = true
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
				} label: {
					Image(systemName: copied ? "checkmark" : "doc.on.doc")
				}
				.accessibilityLabel(copied ? "Copied Diagnostics" : "Copy Diagnostics")
			}
		}
	}
}



struct ZagRepositoryPerformanceView: View {
    var showsLargeTitle = true
    @FetchRequest(
        entity: AltSource.entity(),
        sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)]
    ) private var repositories: FetchedResults<AltSource>

    private func repositoryName(for metricURL: String) -> String {
        let normalized = metricURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if let source = repositories.first(where: {
            $0.sourceURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == normalized
        }), let name = source.name, !name.isEmpty {
            return name
        }
        // A single configured source on an exact host can be identified
        // safely; shared hosts (GitHub, raw.githubusercontent.com, etc.)
        // cannot be attributed to one repository without an exact URL.
        if let host = URL(string: metricURL)?.host?.lowercased() {
            let candidates = repositories.filter {
                $0.sourceURL?.host?.lowercased() == host
            }
            if candidates.count == 1,
               let name = candidates.first?.name, !name.isEmpty {
                return name
            }
        }
        return URL(string: metricURL)?.host ?? metricURL
    }

	@State private var metrics: [NBRepositoryFetchMetric] = []
	@State private var copied = false

	private func reload() {
		metrics = NBRepositoryFetchDiagnostics.metrics
	}

	private func seconds(_ value: Double) -> String {
		String(format: "%.3f s", value)
	}

	private var report: String {
		if metrics.isEmpty {
			return "No repository performance measurements yet."
		}
		return metrics.map { metric in
			[
				metric.url,
				"Status: \(metric.status)",
				"Size: \(ByteCountFormatter.string(fromByteCount: Int64(metric.byteCount), countStyle: .file))",
				"Network: \(seconds(metric.networkSeconds))",
				"Decode: \(seconds(metric.decodeSeconds))",
				"Total: \(seconds(metric.networkSeconds + metric.decodeSeconds))"
			].joined(separator: "\n")
		}.joined(separator: "\n\n")
	}

	var body: some View {
		Form {
			if metrics.isEmpty {
				Section {
					Text("No measurements yet. Refresh Sources once, then return here.")
						.foregroundStyle(.secondary)
				}
			} else {
				ForEach(metrics) { metric in
					Section {
						LabeledContent("Status", value: metric.status)
						LabeledContent(
							"Size",
							value: ByteCountFormatter.string(
								fromByteCount: Int64(metric.byteCount),
								countStyle: .file
							)
						)
						LabeledContent("Network", value: seconds(metric.networkSeconds))
						LabeledContent("Decode", value: seconds(metric.decodeSeconds))
						LabeledContent(
							"Total",
							value: seconds(metric.networkSeconds + metric.decodeSeconds)
						)
					} header: {
						Text(repositoryName(for: metric.url))
					} footer: {
						Text(metric.url)
							.textSelection(.enabled)
					}
				}
			}

			Section {
				Button {
					UIPasteboard.general.string = report
					copied = true
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
				} label: {
					Label(copied ? "Copied" : "Copy Performance Report", systemImage: copied ? "checkmark" : "doc.on.doc")
				}

				Button(role: .destructive) {
					NBRepositoryFetchDiagnostics.clear()
					reload()
				} label: {
					Label("Clear Measurements", systemImage: "trash")
				}
			}
		}
		.navigationTitle(showsLargeTitle ? "Repo Performance" : "")
        .navigationBarTitleDisplayMode(showsLargeTitle ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
		.zagWallpaperSurface()
		.onAppear {
			reload()
		}
		.safeAreaInset(edge: .bottom) {
			Color.clear.frame(height: 48)
		}
	}
}


private struct ZagInstallationDiagnosticsView: View {
	var body: some View {
		NBList("Installation Diagnostics") {
			Section {
				NavigationLink(destination: RPPairingDiagnosticsView().zagSettingsDestinationAvatar()) {
					Label("RPPairing Diagnostics", systemImage: "stethoscope")
				}
			} header: {
				Text("RPPairing")
			}
		}
		.safeAreaInset(edge: .bottom) {
			Color.clear.frame(height: 48)
		}
	}
}



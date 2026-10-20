//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State var appIcon: UIImage?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_cert()
                _signingPreflightSection()
				_customizationProperties(for: app)
				
				// horrible
				Rectangle()
					.foregroundStyle(.clear)
					.frame(height: 30)
					.listRowBackground(EmptyView())
			}
			.overlay {
				VStack(spacing: 0) {
					Spacer()
					NBVariableBlurView()
						.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
						.rotationEffect(.degrees(180))
						.overlay {
							Button {
								_start()
							} label: {
								NBSheetButton(title: .localized("Start Signing"), style: .prominent)
									.padding()
							}
							.buttonStyle(.plain)
							.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
						}
				}
				.ignoresSafeArea(edges: .bottom)
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Image("Glyph")
						.resizable()
						.scaledToFit()
						.frame(height: 38)
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
		}
		.onAppear {
			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					FRAppIconView(app: app, size: 56)
				}
			}
			
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			}
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		}
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				#if NIGHTLY || DEBUG
					NavigationLink(.localized("Entitlements") + " (BETA)") {
						SigningEntitlementsView(
							bindingValue: $_temporaryOptions.appEntitlementsFile
						)
					}
				#endif
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				}
			}
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.navigationTitle(.localized("Properties"))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Signing preflight (local, non-blocking advisory)
extension SigningView {
    @ViewBuilder
    private func _signingPreflightSection() -> some View {
        if _temporaryOptions.signingOption == .default {
            Section {
                if let certificate = _selectedCert() {
                    if let profile = Storage.shared.getProvisionFileDecoded(for: certificate) {
                        let bundleID = _temporaryOptions.appIdentifier ?? app.identifier ?? ""
                        let appID = profile.Entitlements?["application-identifier"]?.value as? String
                            ?? profile.Entitlements?["com.apple.application-identifier"]?.value as? String
                        let bundleMatches = _profileAllows(bundleID, appID: appID, teamIDs: profile.TeamIdentifier)
                        let validDates = profile.CreationDate <= Date() && profile.ExpirationDate > Date()
                        let p12Present = Storage.shared.getFile(.certificate, from: certificate) != nil

                        LabeledContent("Profile", value: profile.Name)
                        _preflightRow("P12 File", okay: p12Present, success: "Present", failure: "Missing")
                        _preflightRow("Profile Dates", okay: validDates, success: "Current", failure: "Not valid")
                        _preflightRow("App Identifier", okay: bundleMatches, success: "Matches profile", failure: "Not matched")
                        if certificate.revoked {
                            Label("Certificate previously marked revoked", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                        } else {
                            Text("Apple revocation status has not been verified.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let entitlementsURL = _temporaryOptions.appEntitlementsFile {
                            let issues = _preflightEntitlementIssues(at: entitlementsURL, profile: profile)
                            if let issues {
                                if issues.isEmpty {
                                    Label("Custom entitlements: no basic conflicts found", systemImage: "checkmark.circle")
                                        .foregroundStyle(Color.green)
                                } else {
                                    DisclosureGroup("Custom entitlements: \(issues.count) warning(s)") {
                                        ForEach(issues, id: \.self) { issue in
                                            Text(issue)
                                                .font(.caption)
                                        }
                                    }
                                }
                            } else {
                                Label("Custom entitlements could not be read", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(Color.orange)
                            }
                        }

                        NavigationLink("Certificate Details") {
                            CertificatesInfoView(cert: certificate)
                        }
                    } else {
                        Label("Provisioning profile unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                    }
                } else {
                    Text("Choose a signing certificate to see preflight diagnostics.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Signing Preflight")
            } footer: {
                Text("Advisory checks only. The final bundle identifier may be changed by signing options. This does not verify the P12 password, Apple's revocation service, actual app entitlements or device registration.")
            }
        }
    }

    private func _preflightRow(_ title: String, okay: Bool, success: String, failure: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: okay ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(okay ? Color.green : Color.orange)
            Text(title)
            Spacer(minLength: 8)
            Text(okay ? success : failure)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    private func _profileAllows(_ bundleID: String, appID: String?, teamIDs: [String]) -> Bool {
        guard !bundleID.isEmpty,
              let appID,
              let separator = appID.firstIndex(of: ".") else { return false }
        let prefix = String(appID[..<separator])
        guard teamIDs.contains(prefix) else { return false }
        let pattern = String(appID[appID.index(after: separator)...])
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") && pattern.filter({ $0 == "*" }).count == 1 {
            let start = String(pattern.dropLast())
            return bundleID.hasPrefix(start) && bundleID.count > start.count
        }
        return bundleID == pattern
    }

    // This compares an explicitly selected entitlement plist, not the
    // entitlements extracted from the imported IPA's code signature.
    private func _preflightEntitlementIssues(at url: URL, profile: Certificate) -> [String]? {
        guard let bytes = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil),
              let requested = raw as? [String: Any],
              let allowed = profile.Entitlements else { return nil }

        var issues: [String] = []
        for key in requested.keys.sorted() {
            guard let requestedValue = requested[key] else { continue }
            guard let profileValue = allowed[key]?.value else {
                issues.append("\(key): not included in profile")
                continue
            }
            if !_preflightValueMatches(requestedValue, allowed: profileValue) {
                issues.append("\(key): requested value differs from profile")
            }
        }
        return issues
    }

    private func _preflightValueMatches(_ requested: Any, allowed: Any) -> Bool {
        if let requested = requested as? String, let allowed = allowed as? String {
            if requested == allowed { return true }
            if allowed.hasSuffix("*") && allowed.filter({ $0 == "*" }).count == 1 {
                return requested.hasPrefix(String(allowed.dropLast()))
            }
            return false
        }
        if let requested = requested as? [String], let allowed = allowed as? [String] {
            return requested.allSatisfy { item in
                allowed.contains { _preflightValueMatches(item, allowed: $0) }
            }
        }
        if let requested = requested as? [String: Any], let allowed = allowed as? [String: Any] {
            return requested.allSatisfy { key, value in
                guard let permitted = allowed[key] else { return false }
                return _preflightValueMatches(value, allowed: permitted)
            }
        }
        if let requested = requested as? NSNumber, let allowed = allowed as? NSNumber {
            return CFGetTypeID(requested) == CFGetTypeID(allowed) && requested == allowed
        }
        if let requested = requested as? Data, let allowed = allowed as? Data {
            return requested == allowed
        }
        return false
    }
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
		if ZagCertificateSelection.asksEveryTime,
		   _temporaryOptions.signingOption == .default {
			Task { @MainActor in
				guard let certificate = await ZagCertificateSelection.chooseForSigning() else {
					return
				}
				_startSigning(using: certificate)
			}
			return
		}

		_startSigning(using: _selectedCert())
	}

	private func _startSigning(using certificate: CertificatePair?) {
		guard
			certificate != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		ZagLogger.shared.info("Manual Signing", "Signing started: \(app.name ?? "Unknown") | id=\(app.identifier ?? "unknown") | version=\(app.version ?? "unknown")")
		_isSigning = true

		var options = _temporaryOptions
		if
			options.ppqProtection,
			let identifier = app.identifier,
			let certificate,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
		}

		FR.signPackageFile(
			app,
			using: options,
			icon: appIcon,
			certificate: certificate
		) { error in
			if let error {
				ZagLogger.shared.error("Manual Signing", "\(app.name ?? "Unknown") | id=\(app.identifier ?? "unknown") | \(error.localizedDescription)")
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					dismiss()
				}

				UIAlertController.showAlert(
					title: "Error",
					message: error.localizedDescription,
					actions: [ok]
				)
			} else {
				ZagLogger.shared.info("Manual Signing", "Signing completed: \(app.name ?? "Unknown") | id=\(options.appIdentifier ?? app.identifier ?? "unknown") | installAfterSigning=\(options.post_installAppAfterSigned) | deleteImported=\(options.post_deleteAppAfterSigned)")
				if
					options.post_deleteAppAfterSigned,
					!app.isSigned
				{
					Storage.shared.deleteApp(for: app)
				}

				if options.post_installAppAfterSigned {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
						NotificationCenter.default.post(
							name: Notification.Name("Feather.installApp"),
							object: nil
						)
					}
				}
				dismiss()
			}
		}
	}}

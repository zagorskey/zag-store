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
    @State private var _originalEntitlementAudit: ZagOriginalEntitlementAudit.Report?
    @State private var _originalEntitlementRunning = false
    @State private var _originalEntitlementRequest = UUID()
	
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
		NBNavigationView("Sign App", displayMode: .inline) {
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
                        _identifierPreflight(
                            originalID: app.identifier ?? "",
                            requestedID: bundleID,
                            profileAppID: appID,
                            matches: bundleMatches,
                            ppqMayChange: _temporaryOptions.ppqProtection && certificate.ppQCheck
                        )
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

                        _originalEntitlementInspection(profile: profile)

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
                Text("Read-only guidance, not signing authorization. Final identifiers and entitlements may change during signing. P12 password, Apple revocation, signed output and device registration are not verified here.")
            }
        }
    }

    @ViewBuilder
    private func _identifierPreflight(
        originalID: String,
        requestedID: String,
        profileAppID: String?,
        matches: Bool,
        ppqMayChange: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: matches && !ppqMayChange ? "checkmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(matches && !ppqMayChange ? Color.green : Color.secondary)
            Text("App Identifier")
            Spacer(minLength: 8)
            Text(matches && !ppqMayChange ? "Pattern matches" : "Not verified")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        if !matches || ppqMayChange {
            Text("The profile's App ID does not establish the identifier that will be used after re-signing. This is not a certificate failure.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        DisclosureGroup("Identifier Comparison") {
            LabeledContent("Original App") {
                Text(originalID.isEmpty ? "Unavailable" : originalID)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Requested") {
                Text(requestedID.isEmpty ? "Unavailable" : requestedID)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Profile App ID") {
                Text(profileAppID ?? "Unavailable")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if ppqMayChange {
                Text("PPQ protection can override the requested identifier at signing time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Comparison uses the current signing options and selected profile. It does not inspect a finished signed IPA.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func _originalEntitlementInspection(profile: Certificate) -> some View {
        Button {
            _inspectOriginalEntitlements(profile: profile)
        } label: {
            HStack(spacing: 8) {
                if _originalEntitlementRunning {
                    ProgressView()
                } else {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                Text("Inspect Original App Entitlements")
            }
        }
        .disabled(_originalEntitlementRunning)
        .onChange(of: _temporaryCertificate) { _ in
            _originalEntitlementRequest = UUID()
            _originalEntitlementAudit = nil
            _originalEntitlementRunning = false
        }

        if let report = _originalEntitlementAudit {
            VStack(alignment: .leading, spacing: 5) {
                Label(report.title, systemImage: report.error != nil
                      ? "questionmark.circle" : "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(report.error != nil ? Color.orange : Color.secondary)
                Text(report.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !report.issues.isEmpty {
                DisclosureGroup("Original capabilities to review (\(report.issues.count))") {
                    ForEach(report.issues, id: \.self) { issue in
                        Text(issue)
                            .font(.caption)
                    }
                }
            }
            if !report.identityKeys.isEmpty {
                DisclosureGroup("Identity-bound keys (\(report.identityKeys.count))") {
                    ForEach(report.identityKeys, id: \.self) { key in
                        Text(key)
                            .font(.caption)
                    }
                    Text("These values may change during re-signing; the original values are not treated as final signing conflicts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func _inspectOriginalEntitlements(profile: Certificate) {
        guard !_originalEntitlementRunning else { return }
        guard let appURL = Storage.shared.getAppDirectory(for: app),
              let executable = Bundle(url: appURL)?.executableURL else {
            _originalEntitlementAudit = .init(
                inspected: 0, issues: [], identityKeys: [],
                error: "The imported application's executable is unavailable."
            )
            return
        }

        // Capture immutable property-list bytes instead of moving Core Data
        // objects or non-Sendable dictionaries into the detached task.
        let profileValues = profile.Entitlements?.mapValues { $0.value } ?? [:]
        guard PropertyListSerialization.propertyList(profileValues, isValidFor: .xml),
              let profileData = try? PropertyListSerialization.data(
                fromPropertyList: profileValues, format: .xml, options: 0
              ) else {
            _originalEntitlementAudit = .init(
                inspected: 0, issues: [], identityKeys: [],
                error: "The selected profile's entitlements could not be decoded."
            )
            return
        }

        let request = UUID()
        _originalEntitlementRequest = request
        _originalEntitlementRunning = true
        _originalEntitlementAudit = nil
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                ZagOriginalEntitlementAudit.inspect(executable: executable, profileData: profileData)
            }.value
            guard _originalEntitlementRequest == request else { return }
            _originalEntitlementAudit = report
            _originalEntitlementRunning = false
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

// MARK: - Original code-signature entitlement audit
// Reports only capabilities present in the existing main executable.
// Does not claim to know the entitlements the signer will finally generate.
private enum ZagOriginalEntitlementAudit {
    struct Report: Sendable {
        let inspected: Int
        let issues: [String]
        let identityKeys: [String]
        let error: String?

        var title: String {
            if error != nil { return "Original signature not inspected" }
            return issues.isEmpty ? "Original capabilities inspected" : "Original capabilities need review"
        }
        var summary: String {
            if let error { return error }
            return "\(inspected) original entitlement(s), \(issues.count) difference(s) from the selected profile. Original capabilities may be replaced during re-signing; these are not confirmed signing failures."
        }
    }

    static func inspect(executable: URL, profileData: Data) -> Report {
        let original: [String: Any]
        do {
            original = try ZagMachOSignatureInspector.entitlements(at: executable)
        } catch ZagMachOSignatureInspector.InspectionError.unsupportedFormat {
            return Report(inspected: 0, issues: [], identityKeys: [],
                          error: "This Mach-O format is not supported by the current signature inspector (for example, a fat binary).")
        } catch ZagMachOSignatureInspector.InspectionError.missingEntitlements {
            return Report(inspected: 0, issues: [], identityKeys: [],
                          error: "No XML entitlements were found in the original executable's signature.")
        } catch {
            return Report(inspected: 0, issues: [], identityKeys: [],
                          error: "Unable to inspect the original executable's code-signature entitlements.")
        }
        guard let profile = (try? PropertyListSerialization.propertyList(
            from: profileData, options: [], format: nil
        )) as? [String: Any] else {
            return Report(inspected: original.count, issues: [], identityKeys: [],
                          error: "The selected provisioning profile's entitlements are unreadable.")
        }

        // Original app and team identifiers commonly change on re-signing.
        let identityKeys: Set<String> = [
            "application-identifier",
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "com.apple.security.application-groups",
            "com.apple.developer.ubiquity-kvstore-identifier",
            "com.apple.developer.icloud-container-identifiers",
            "get-task-allow"
        ]
        let ignored = original.keys.filter { identityKeys.contains($0) }.sorted()
        var issues: [String] = []
        for key in original.keys.sorted() where !identityKeys.contains(key) {
            guard let value = original[key] else { continue }
            guard let permitted = profile[key] else {
                issues.append("\(key): present in original app, absent from selected profile")
                continue
            }
            if !matches(value, permitted) {
                issues.append("\(key): original value differs from selected profile")
            }
        }
        return Report(inspected: original.count, issues: issues, identityKeys: ignored, error: nil)
    }

    private static func matches(_ original: Any, _ allowed: Any) -> Bool {
        if let lhs = original as? String, let rhs = allowed as? String {
            if lhs == rhs { return true }
            if rhs.hasSuffix("*"), rhs.filter({ $0 == "*" }).count == 1 {
                return lhs.hasPrefix(String(rhs.dropLast()))
            }
            return false
        }
        if let lhs = original as? [String], let rhs = allowed as? [String] {
            return lhs.allSatisfy { item in rhs.contains { matches(item, $0) } }
        }
        if let lhs = original as? [String: Any], let rhs = allowed as? [String: Any] {
            return lhs.allSatisfy { key, value in
                guard let permitted = rhs[key] else { return false }
                return matches(value, permitted)
            }
        }
        if let lhs = original as? NSNumber, let rhs = allowed as? NSNumber {
            return CFGetTypeID(lhs) == CFGetTypeID(rhs) && lhs == rhs
        }
        if let lhs = original as? Data, let rhs = allowed as? Data {
            return lhs == rhs
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

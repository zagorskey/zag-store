//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import CoreData
import IDeviceSwift

struct DownloadButtonView: View {
	let app: ASRepository.App
	var source: ASRepository? = nil
	var title: String = .localized("Get")

	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var pairingCore = ZagRPPairingCore.shared
	@Environment(\.colorScheme) private var colorScheme

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?
	@State private var zagPhase: ZagGetPhase = .idle
	@State private var installedBundleID: String?
	@State private var installationProgress: Double = 0
	@State private var transactionError: String?
	@State private var ringRotation: Double = 0
	@State private var actionClaimed = false
	@State private var palInspectionInProgress = false
	@State private var palInspectionResult: String?

	private var pillBackground: Color {
		colorScheme == .dark
			? Color(hex: "#1C1C1E")
			: Color(hex: "#F2F2F7")
	}

	@AppStorage("Feather.userTintColor")
	private var userTintColor: String = "#4395F8"

	private var pillForeground: Color {
		Color(hex: userTintColor)
	}

	var body: some View {
		VStack(spacing: 3) {
			ZStack {
				if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) {
					_progressRing(progress: downloadProgress, showsStop: downloadProgress < 0.75)
						.onTapGesture {
							if downloadProgress <= 0.75 {
								downloadManager.cancelDownload(currentDownload)
							}
						}
				} else if zagPhase == .downloading {
					_indeterminateRing()
				} else if zagPhase == .signing {
					_indeterminateRing()
				} else if zagPhase == .installing {
					if installationProgress > 0.03 {
						_progressRing(progress: installationProgress, showsStop: false)
					} else {
						_indeterminateRing()
					}
				} else if _isPALApp {
					if palInspectionInProgress {
						ProgressView()
							.frame(width: 88, height: 34, alignment: .center)
					} else {
						ZagActionPill(title: "PAL") {
							_inspectPALPackage()
						}
						.accessibilityLabel(Text("Inspect AltStore PAL package for \(app.currentName)"))
					}
				} else if let bundleID = app.id,
						  installedBundleID == bundleID {
					ZagActionPill(title: .localized("Open")) {
						_performAction(claim: false) {
							UIApplication.openApp(with: bundleID)
						}
					}
					.accessibilityLabel(Text("Open \(app.currentName)"))
				} else if let bundleID = app.id,
						  pairingCore.isInstalled(bundleID: bundleID),
						  _matchesTrackedVariant(bundleID: bundleID) {
					switch _installedReleaseRelationship(bundleID: bundleID) {
					case .newer:
						ZagActionPill(title: .localized("Update")) {
							_performAction { _startGetAndInstall() }
						}
						.disabled(actionClaimed)
						.accessibilityLabel(Text("Update \(app.currentName)"))
					case .same:
						ZagActionPill(title: .localized("Open")) {
							_performAction(claim: false) {
								UIApplication.openApp(with: bundleID)
							}
						}
						.accessibilityLabel(Text("Open \(app.currentName)"))
					case .older:
						ZagActionPill(title: .localized("Revert")) {
							_performAction { _startGetAndInstall() }
						}
						.disabled(actionClaimed)
						.accessibilityLabel(Text("Revert \(app.currentName)"))
					case .unknown:
						ZagActionPill(title: .localized("Open")) {
							UIApplication.openApp(with: bundleID)
						}
					}
				} else if let bundleID = app.id,
						  _hasInstalledTrackedAlternative(bundleID: bundleID) {
					ZagActionPill(title: .localized("Switch")) {
						_performAction { _startGetAndInstall() }
					}
					.disabled(actionClaimed)
					.accessibilityLabel(Text("Switch to \(app.currentName)"))
				} else if _hasLocalSignedCopy {
					ZagActionPill(title: .localized("Install")) {
						_performAction { _installExistingSignedCopy() }
					}
					.disabled(actionClaimed)
					.accessibilityLabel(Text("Install \(app.currentName)"))
				} else {
					ZagActionPill(title: title) {
						_performAction { _startGetAndInstall() }
					}
					.disabled(actionClaimed)
					.accessibilityLabel(Text("\(title) \(app.currentName)"))
				}
			}
			.frame(width: 88, height: 34, alignment: .center)

			if let caption = _actionCaption {
				Text(caption.text)
					.font(.system(size: 10, weight: .regular))
					.foregroundStyle(caption.color)
					.lineLimit(1)
					.minimumScaleFactor(0.75)
					.frame(width: 88, height: 11)
					.padding(.top, 1)
			} else {
				Color.clear
					.frame(width: 88, height: 12)
			}
		}
		.onAppear(perform: setupObserver)
		.onDisappear { cancellable?.cancel() }
		.alert(.localized("Unable to Install"), isPresented: Binding(
			get: { transactionError != nil },
			set: { if !$0 { transactionError = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(transactionError ?? "")
		}
		.alert("PAL Package", isPresented: Binding(
			get: { palInspectionResult != nil },
			set: { if !$0 { palInspectionResult = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(palInspectionResult ?? "")
		}
		.onChange(of: downloadManager.downloads.description) { _ in
			setupObserver()
		}
		.onChange(of: zagPhase) { phase in
			if phase == .idle {
				actionClaimed = false
			}
		}
		.animation(.easeInOut(duration: 0.25), value: zagPhase)
	}

	private struct PALManifest: Decodable {
		struct Variant: Decodable {
			struct InstallTarget: Decodable {
				let device: String?
				let os: String?
			}

			let publicId: String?
			let assetPath: String?
			let installTargets: [InstallTarget]?
			let alternativeDistributionKeyBlob: String?
			let sha256: String?
			let size: Int64?
		}

		let distributionPackageRevision: Int?
		let appleItemId: String?
		let bundleId: String?
		let shortVersionString: String?
		let bundleVersion: String?
		let appleVersionId: String?
		let platforms: [String]?
		let minimumSystemVersions: [String: String]?
		let variants: [Variant]?
	}

	private func _inspectPALPackage() {
		guard !palInspectionInProgress else { return }
		guard let manifestURL = app.currentDownloadUrl else {
			transactionError = .localized("This PAL app does not provide an Alternative Distribution Package manifest URL.")
			return
		}

		palInspectionInProgress = true
		Task {
			do {
				let (data, response) = try await URLSession.shared.data(from: manifestURL)
				if let http = response as? HTTPURLResponse,
				   !(200...299).contains(http.statusCode) {
					throw URLError(.badServerResponse)
				}

				let manifest = try JSONDecoder().decode(PALManifest.self, from: data)
				let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
				let rawVariants = rawObject?["variants"] as? [[String: Any]] ?? []
				let deviceModel = UIDevice.current.zagPALHardwareIdentifier
				let variants = manifest.variants ?? []
				let matchingIndices = variants.indices.filter { index in
					guard let targets = variants[index].installTargets else { return false }
					return targets.contains { $0.device == deviceModel }
				}

				let platformText = (manifest.platforms ?? []).joined(separator: ", ")
				let minimumOS = manifest.minimumSystemVersions?["ios"] ?? "Unknown"
				let version = manifest.shortVersionString ?? app.currentVersion ?? "Unknown"
				let build = manifest.bundleVersion ?? app.currentAppVersion?.build ?? "Unknown"
				let marketplaceID = app.marketplaceID ?? manifest.appleItemId ?? "Unknown"

				var lines = [
					"App: \(app.currentName)",
					"Bundle ID: \(manifest.bundleId ?? app.id ?? "Unknown")",
					"Marketplace ID: \(marketplaceID)",
					"Version: \(version) (\(build))",
					"Platform: \(platformText.isEmpty ? "Unknown" : platformText)",
					"Minimum iOS: \(minimumOS)",
					"Device: \(deviceModel)",
					"Variants: \(variants.count)",
					"Matching device variants: \(matchingIndices.count)"
				]

				for (position, index) in matchingIndices.enumerated() {
					let variant = variants[index]
					let raw = rawVariants.indices.contains(index) ? rawVariants[index] : [:]
					let assetPath = variant.assetPath ?? (raw["assetPath"] as? String) ?? "Unknown"
					let resolvedAssetURL = assetPath == "Unknown"
						? "Unknown"
						: (URL(string: assetPath, relativeTo: manifestURL)?.absoluteURL.absoluteString ?? assetPath)
					let targets = (variant.installTargets ?? []).map {
						[$0.device, $0.os].compactMap { $0 }.joined(separator: " / ")
					}.joined(separator: ", ")
					let keyBlobPresent =
						variant.alternativeDistributionKeyBlob != nil ||
						raw["alternativeDistributionKeyBlob"] != nil
					let hash =
						variant.sha256 ??
						(raw["sha256"] as? String) ??
						(raw["hash"] as? String)
					let size =
						variant.size.map(String.init) ??
						(raw["size"] as? NSNumber)?.stringValue

					lines.append("")
					lines.append("Matching Variant \(position + 1)")
					lines.append("Public ID: \(variant.publicId ?? (raw["publicId"] as? String) ?? "Unknown")")
					lines.append("Asset path: \(assetPath)")
					lines.append("Asset URL: \(resolvedAssetURL)")
					lines.append("Targets: \(targets.isEmpty ? "Unknown" : targets)")
					lines.append("Key blob: \(keyBlobPresent ? "Present" : "Not exposed")")
					if let hash { lines.append("Hash: \(hash)") }
					if let size { lines.append("Size: \(size) bytes") }
					let knownKeys = Set(["publicId", "assetPath", "installTargets", "alternativeDistributionKeyBlob", "sha256", "hash", "size"])
					let extraKeys = raw.keys.filter { !knownKeys.contains($0) }.sorted()
					if !extraKeys.isEmpty {
						lines.append("Other metadata: \(extraKeys.joined(separator: ", "))")
					}
				}

				lines.append("")
				lines.append("Inspection only — no PAL asset was installed or passed to Zag Store's IPA signing path.")

				await MainActor.run {
					palInspectionInProgress = false
					palInspectionResult = lines.joined(separator: "\n")
				}
			} catch {
				await MainActor.run {
					palInspectionInProgress = false
					transactionError = "PAL manifest inspection failed: \(error.localizedDescription)"
				}
			}
		}
	}

	private var _isPALApp: Bool {
		guard let marketplaceID = app.marketplaceID else { return false }
		return !marketplaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private func _performAction(
		claim: Bool = true,
		_ action: () -> Void
	) {
		guard !actionClaimed else { return }
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		if claim {
			actionClaimed = true
		}
		action()
	}

	private var _actionCaption: (text: String, color: Color)? {
		if !_stageCaption.isEmpty {
			return (_stageCaption, .secondary)
		}

		if
			let bundleID = app.id,
			pairingCore.isInstalled(bundleID: bundleID),
			_matchesTrackedVariant(bundleID: bundleID),
			let expiration = _installedCertificateExpiration(bundleID: bundleID)
		{
			let info = expiration.expirationInfo()
			return (info.formatted, info.color)
		}

		if let modificationLabel = _modificationLabel {
			return (modificationLabel, .secondary)
		}
		return nil
	}

	private func _installedCertificateExpiration(bundleID: String) -> Date? {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.predicate = NSPredicate(format: "identifier == %@", bundleID)
		guard let signed = try? Storage.shared.context.fetch(request).first else {
			return nil
		}

		if let certificate = Storage.shared.getCertificate(from: signed) {
			return certificate.expiration
		}

		let certificates = Storage.shared.getAllCertificates()
		let selectedIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		if certificates.indices.contains(selectedIndex) {
			return certificates[selectedIndex].expiration
		}
		return certificates.first?.expiration
	}

	private var _modificationLabel: String? {
		let fields: [String] = [
			app.currentAppVersion?.localizedDescription,
			app.versionDescription,
			app.subtitle,
			app.localizedDescription,
			app.description
		].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
		let text = fields.joined(separator: "\n").lowercased()

		// Source metadata has no standardized modification flag. Keep these
		// matches deliberately explicit: this label reports what the source
		// declares, rather than claiming Zag Store inspected the IPA itself.
		let rules: [(String, String)] = [
			("tweak injected", "Tweak Injected"),
			("tweaks injected", "Tweak Injected"),
			("injected with", "Injected"),
			("injected", "Injected"),
			("cracked", "Cracked"),
			("patched", "Patched"),
			("modified", "Modified"),
			("modded", "Modified")
		]
		return rules.first { text.contains($0.0) }?.1
	}

	private var _stageCaption: String {
		switch zagPhase {
		case .downloading: return .localized("Downloading…")
		case .signing: return .localized("Preparing…")
		case .installing: return .localized("Installing…")
		default: return ""
		}
	}

	private func _indeterminateRing() -> some View {
		ZStack {
			Circle()
				.stroke(pillForeground.opacity(0.22), lineWidth: 2.3)
			Circle()
				.trim(from: 0.08, to: 0.72)
				.stroke(pillForeground, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
				.rotationEffect(.degrees(ringRotation - 90))
		}
		.frame(width: 31, height: 31)
		.onAppear {
			ringRotation = 0
			withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
				ringRotation = 360
			}
		}
	}

	@ViewBuilder
	private func _progressRing(progress: Double, showsStop: Bool) -> some View {
		ZStack {
			Circle()
				.stroke(pillForeground.opacity(0.22), lineWidth: 2.3)
			Circle()
				.trim(from: 0, to: max(0.03, min(1, progress)))
				.stroke(pillForeground, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
				.rotationEffect(.degrees(-90))
			if showsStop {
				Image(systemName: "square.fill")
					.foregroundStyle(pillForeground)
					.font(.footnote)
			} else if progress >= 1 {
				Image(systemName: "checkmark")
					.foregroundStyle(pillForeground)
					.font(.footnote.bold())
			}
		}
		.frame(width: 31, height: 31)
		.animation(.smooth, value: progress)
	}


	private enum InstalledReleaseRelationship {
		case newer
		case same
		case older
		case unknown
	}

	private func _installedReleaseRelationship(
		bundleID: String
	) -> InstalledReleaseRelationship {
		guard
			let installed = pairingCore.installedAppInfo(bundleID: bundleID),
			let repositoryVersion = app.currentVersion,
			!repositoryVersion.isEmpty,
			!installed.version.isEmpty
		else {
			return .unknown
		}

		let versionResult = _compareReleaseValue(
			repositoryVersion,
			installed.version
		)

		if versionResult == .orderedDescending { return .newer }
		if versionResult == .orderedAscending { return .older }

		let repositoryBuild = app.currentAppVersion?.build
		guard
			let repositoryBuild,
			!repositoryBuild.isEmpty,
			!installed.build.isEmpty
		else {
			return .same
		}

		let buildResult = _compareReleaseValue(
			repositoryBuild,
			installed.build
		)
		if buildResult == .orderedDescending { return .newer }
		if buildResult == .orderedAscending { return .older }
		return .same
	}

	private func _compareReleaseValue(
		_ lhs: String,
		_ rhs: String
	) -> ComparisonResult {
		let lhsParts = lhs.split { !$0.isNumber }.compactMap { Int($0) }
		let rhsParts = rhs.split { !$0.isNumber }.compactMap { Int($0) }

		if !lhsParts.isEmpty, !rhsParts.isEmpty {
			let count = max(lhsParts.count, rhsParts.count)
			for index in 0..<count {
				let left = index < lhsParts.count ? lhsParts[index] : 0
				let right = index < rhsParts.count ? rhsParts[index] : 0
				if left != right {
					return left < right ? .orderedAscending : .orderedDescending
				}
			}
			return .orderedSame
		}

		return lhs.compare(
			rhs,
			options: [.numeric, .caseInsensitive]
		)
	}

	private var _hasLocalSignedCopy: Bool {
		_existingSignedCopy() != nil
	}

	private func _existingSignedCopy() -> Signed? {
		guard
			let bundleID = app.id,
			!bundleID.isEmpty,
			let repositoryVersion = app.currentVersion,
			!repositoryVersion.isEmpty
		else {
			return nil
		}

		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.predicate = NSPredicate(format: "identifier == %@", bundleID)

		guard let candidates = try? Storage.shared.context.fetch(request) else {
			return nil
		}

		return candidates.first { signed in
			guard
				let signedVersion = signed.version,
				!signedVersion.isEmpty,
				_compareReleaseValue(signedVersion, repositoryVersion) == .orderedSame
			else {
				return false
			}

			guard
				let repositoryBuild = app.currentAppVersion?.build,
				!repositoryBuild.isEmpty,
				let signedBuild = _signedBuildVersion(signed),
				!signedBuild.isEmpty
			else {
				// A matching version is sufficient when either side does not
				// expose a build number.
				return true
			}

			return _compareReleaseValue(
				signedBuild,
				repositoryBuild
			) == .orderedSame
		}
	}

	private func _signedBuildVersion(_ signed: Signed) -> String? {
		guard
			let appURL = Storage.shared.getAppDirectory(for: signed),
			let bundle = Bundle(url: appURL)
		else {
			return nil
		}
		return bundle.object(
			forInfoDictionaryKey: "CFBundleVersion"
		) as? String
	}

	private func _installExistingSignedCopy() {
		guard zagPhase == .idle, let signed = _existingSignedCopy() else { return }
		zagPhase = .installing
		installationProgress = 0
		_installInline(signed)
	}

	private func _hasInstalledTrackedAlternative(bundleID: String) -> Bool {
		let defaults = UserDefaults.standard
		let variantOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]

		guard
			let trackedVariant = variantOrigins[bundleID],
			trackedVariant != UpdateManager.variantIdentity(for: app)
		else {
			return false
		}

		// The device inventory is authoritative when available. A tracked
		// lineage is also sufficient here because it is only written after a
		// successful install (or explicit legacy adoption), and it lets a
		// repository sibling offer variant replacement even while the pairing
		// inventory is refreshing.
		if pairingCore.isInstalled(bundleID: bundleID) {
			return true
		}
		let appOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		return appOrigins[bundleID] != nil
	}

	private func _matchesTrackedVariant(bundleID: String) -> Bool {
		let defaults = UserDefaults.standard
		let variantOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]

		if let trackedVariant = variantOrigins[bundleID] {
			return trackedVariant == UpdateManager.variantIdentity(for: app)
		}

		let appOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		guard let trackedApp = appOrigins[bundleID] else {
			// Preserve legacy behavior until the user adopts an ambiguous variant.
			return true
		}
		return trackedApp.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased().filter { $0.isLetter || $0.isNumber } ==
			app.currentName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased().filter { $0.isLetter || $0.isNumber }
	}

	private func _rememberRepositoryOrigin() {
		guard let bundleID = app.id, !bundleID.isEmpty else { return }
		var origins = UserDefaults.standard.dictionary(forKey: "zagStore.repositoryOrigins") as? [String: String] ?? [:]
		var originIcons = UserDefaults.standard.dictionary(forKey: "zagStore.repositoryOriginIcons") as? [String: String] ?? [:]
		var appOrigins = UserDefaults.standard.dictionary(forKey: "zagStore.repositoryAppOrigins") as? [String: String] ?? [:]

		let repositoryKey =
			source?.id ??
			source?.website?.absoluteString ??
			source?.name

		if let repositoryKey, !repositoryKey.isEmpty {
			origins[bundleID] = repositoryKey
			UserDefaults.standard.set(origins, forKey: "zagStore.repositoryOrigins")
		}

		let appIdentity = app.currentName.trimmingCharacters(in: .whitespacesAndNewlines)
		if !appIdentity.isEmpty {
			appOrigins[bundleID] = appIdentity
			UserDefaults.standard.set(appOrigins, forKey: "zagStore.repositoryAppOrigins")
		}

		var variantOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]
		variantOrigins[bundleID] = UpdateManager.variantIdentity(for: app)
		UserDefaults.standard.set(
			variantOrigins,
			forKey: "zagStore.repositoryVariantOrigins"
		)

		if let iconURL = source?.currentIconURL?.absoluteString {
			originIcons[bundleID] = iconURL
			UserDefaults.standard.set(originIcons, forKey: "zagStore.repositoryOriginIcons")
		}
	}

	private func _startGetAndInstall() {
		guard !_isPALApp else {
			transactionError = .localized(
				"This app uses AltStore PAL's Alternative Distribution Package format. Zag Store can read this source, but PAL installation support is still being implemented."
			)
			return
		}
		guard zagPhase == .idle, let url = app.currentDownloadUrl else { return }
		ZagLogger.shared.info("Repository Install", "Download started: \(app.currentName) | id=\(app.id ?? "unknown") | version=\(app.currentVersion ?? "unknown")")
		zagPhase = .downloading

		_ = downloadManager.startDownload(
			from: url,
			id: app.currentUniqueId,
			zagImported: { uuid, error in
				DispatchQueue.main.async {
					if let error {
						if (error as? URLError)?.code == .cancelled {
							zagPhase = .idle
						} else {
							_failTransaction(error.localizedDescription)
						}
						return
					}
					ZagLogger.shared.info("Repository Install", "Download/import completed: \(app.currentName) | importedUUID=\(uuid ?? "unknown")")
					guard let uuid, let imported = _importedApp(uuid: uuid) else {
						_failTransaction(.localized("The downloaded app was imported, but Zag Store could not locate it for signing."))
						return
					}
					_signAndInstall(imported)
				}
			}
		)
	}

	private func _signAndInstall(_ imported: Imported) {
		Task { @MainActor in
			guard let certificate = await ZagCertificateSelection.chooseForSigning() else {
				if Storage.shared.getAllCertificates().isEmpty {
					_failTransaction(
						.localized("The app was downloaded and kept in Imported, but no signing certificate is selected.")
					)
				} else {
					zagPhase = .idle
				}
				return
			}
			_signAndInstall(imported, certificate: certificate)
		}
	}

	private func _signAndInstall(
		_ imported: Imported,
		certificate: CertificatePair
	) {
		ZagLogger.shared.info("Signing", "Signing started: \(app.currentName) | id=\(imported.identifier ?? app.id ?? "unknown")")
		zagPhase = .signing
		var options = OptionsManager.shared.options

		if
			options.ppqProtection,
			let identifier = imported.identifier,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(options.ppqString)"
		}
		if
			let identifier = imported.identifier,
			let mappedIdentifier = options.identifiers[identifier]
		{
			options.appIdentifier = mappedIdentifier
		}
		if
			let name = imported.name,
			let mappedName = options.displayNames[name]
		{
			options.appName = mappedName
		}

		var signedUUID: String?
		FR.signPackageFile(
			imported,
			using: options,
			icon: nil,
			certificate: certificate,
			signedUUID: { signedUUID = $0 }
		) { error in
			if let error {
				_failTransaction(error.localizedDescription)
				return
			}
			ZagLogger.shared.info("Signing", "Signing completed: \(app.currentName) | signedUUID=\(signedUUID ?? "unknown")")
			guard let signedUUID, let signed = _signedApp(uuid: signedUUID) else {
				_failTransaction(.localized("Signing completed, but Zag Store could not locate the signed app."))
				return
			}
			zagPhase = .installing
			installationProgress = 0
			_installInline(signed, imported: imported)
		}
	}

	private func _installInline(_ signed: Signed, imported: Imported? = nil) {
		let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		let serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")
		ZagLogger.shared.info("Installation", "Install started: \(signed.name ?? app.currentName) | id=\(signed.identifier ?? "unknown") | method=\(method)")

		Task {
			do {
				let status = InstallerStatusViewModel(isIdevice: method == 1)
				let archive = ArchiveHandler(app: signed, viewModel: status)
				try await archive.move()
				let packageURL = try await archive.archive()

				if method == 0 {
					guard serverMethod == 0 else {
						throw ZagInlineInstallError.semiLocalRequiresPreview
					}
					let server = try ServerInstaller(app: signed, viewModel: status)
					server.packageUrl = packageURL
					status.status = .ready
					guard let installURL = URL(string: server.iTunesLink) else {
						throw ZagInlineInstallError.invalidInstallURL
					}
					await UIApplication.shared.open(installURL)
					try await _pollInstall(bundleID: signed.identifier ?? "")
				} else if method == 1 {
					let proxy = InstallationProxy(viewModel: status)
					try await proxy.install(at: packageURL, suspend: false)
					installationProgress = 1
				} else {
					try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
						do {
							try ZagRPPairingCore.shared.installGate4IPA(
								at: packageURL,
								deviceIP: "10.7.0.1",
								progress: { percent in
									installationProgress = Double(percent) / 100.0
								}
							) { result in
								switch result {
								case .success: continuation.resume()
								case .failure(let error): continuation.resume(throwing: error)
								}
							}
							} catch {
								continuation.resume(throwing: error)
							}
						}
					installationProgress = 1
				}

				installedBundleID = signed.identifier
				_rememberRepositoryOrigin()
				_markManagedInstalled(signed)
				_removeSupersededSignedCopies(keeping: signed)
				if let imported {
					Storage.shared.deleteApp(for: imported)
				}
				try? pairingCore.refreshInstalledApps()
				ZagLogger.shared.info("Installation", "Install completed: \(signed.name ?? app.currentName) | id=\(signed.identifier ?? "unknown") | temporaryImportRemoved=\(imported != nil)")
				zagPhase = .idle
			} catch {
				_failTransaction(error.localizedDescription)
			}
		}
	}

	private func _markManagedInstalled(_ signed: Signed) {
		guard let bundleID = signed.identifier, !bundleID.isEmpty else { return }
		let key = "zagStore.managedInstalledBundleIDs"
		let defaults = UserDefaults.standard
		let currentData = defaults.data(forKey: key) ?? Data()
		var identifiers =
			(try? JSONDecoder().decode(Set<String>.self, from: currentData)) ?? []
		identifiers.insert(bundleID)
		if let encoded = try? JSONEncoder().encode(identifiers) {
			defaults.set(encoded, forKey: key)
		}
	}

	private func _removeSupersededSignedCopies(keeping installed: Signed) {
		guard
			let bundleID = installed.identifier,
			!bundleID.isEmpty
		else {
			return
		}

		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.predicate = NSPredicate(format: "identifier == %@", bundleID)

		guard let copies = try? Storage.shared.context.fetch(request) else {
			return
		}

		for copy in copies where copy.objectID != installed.objectID {
			Storage.shared.deleteApp(for: copy)
		}
	}

	private func _pollInstall(bundleID: String) async throws {
		guard !bundleID.isEmpty else { throw ZagInlineInstallError.missingBundleIdentifier }
		var started = false
		for _ in 0..<600 {
			let raw = UIApplication.installProgress(for: bundleID) ?? 0
			if raw > 0 { started = true }
			if started {
				installationProgress = min(1, max(0.03, (raw - 0.6) / 0.3))
				if raw == 0 {
					installationProgress = 1
					return
				}
			}
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		throw ZagInlineInstallError.installTimedOut
	}

	private func _importedApp(uuid: String) -> Imported? {
		let request = NSFetchRequest<Imported>(entityName: "Imported")
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? Storage.shared.context.fetch(request).first
	}

	private func _signedApp(uuid: String) -> Signed? {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? Storage.shared.context.fetch(request).first
	}

	private func _failTransaction(_ message: String) {
		ZagLogger.shared.error("Repository Transaction", "\(app.currentName) | id=\(app.id ?? "unknown") | \(message)")
		zagPhase = .idle
		transactionError = message
	}

	private func setupObserver() {
		cancellable?.cancel()

		guard let download = downloadManager.getDownload(
			by: app.currentUniqueId
		) else {
			downloadProgress = 0
			return
		}

		downloadProgress = download.overallProgress

		let publisher = Publishers.CombineLatest(
			download.$progress,
			download.$unpackageProgress
		)

		cancellable = publisher.sink { _, _ in
			downloadProgress =
				download.overallProgress
		}
	}
	private enum ZagGetPhase: Equatable {
		case idle
		case downloading
		case signing
		case installing
	}

	private enum ZagInlineInstallError: LocalizedError {
		case semiLocalRequiresPreview
		case invalidInstallURL
		case missingBundleIdentifier
		case installTimedOut

		var errorDescription: String? {
			switch self {
			case .semiLocalRequiresPreview: return "Semi Local installation still requires the installation preview. Choose Fully Local, idevice, or RPPairing for inline repository installs."
			case .invalidInstallURL: return "Zag Store could not create the local installation URL."
			case .missingBundleIdentifier: return "The signed app has no bundle identifier."
			case .installTimedOut: return "Zag Store could not confirm that installation completed."
			}
		}
	}

}
private extension UIDevice {
	var zagPALHardwareIdentifier: String {
		var systemInfo = utsname()
		uname(&systemInfo)
		return withUnsafePointer(to: &systemInfo.machine) {
			$0.withMemoryRebound(to: CChar.self, capacity: 1) {
				String(cString: $0)
			}
		}
	}
}


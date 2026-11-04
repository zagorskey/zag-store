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
	/// The authoritative per-job state; survives scrolling and Shortcuts handoffs.
	@ObservedObject private var jobs = ZagInstallJobs.shared
	@Environment(\.colorScheme) private var colorScheme

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?
	@State private var installedBundleID: String?
	@State private var transactionError: String?
	@State private var retrySignedUUID: String?
	@State private var retryImportedUUID: String?
	@State private var actionClaimed = false
	@State private var isPALInfoPresented = false

	// A successful repository download remains in history even after its
	// Imported, Signed, and Installed records are deleted.
	@State private var wasDownloadedBefore = false
	private let downloadHistoryKey = "zagStore.previouslyDownloadedBundleIDs"

	private func _refreshDownloadHistory() {
		guard let id = app.id, !id.isEmpty else { wasDownloadedBefore = false; return }
		let history = UserDefaults.standard.stringArray(forKey: downloadHistoryKey) ?? []
		let legacyOrigins = UserDefaults.standard.dictionary(forKey: "zagStore.repositoryOrigins") ?? [:]
		wasDownloadedBefore = history.contains(id) || legacyOrigins[id] != nil
	}

	private func _rememberSuccessfulDownload() {
		guard let id = app.id, !id.isEmpty else { return }
		var history = UserDefaults.standard.stringArray(forKey: downloadHistoryKey) ?? []
		if !history.contains(id) {
			history.append(id)
			UserDefaults.standard.set(history, forKey: downloadHistoryKey)
		}
		wasDownloadedBefore = true
	}

	// MARK: Install job

	private var _jobKey: String { "repository:\(app.currentUniqueId)" }

	/// The row's coarse phase, read from and written to the shared job.
	private var zagPhase: ZagGetPhase {
		get {
			guard let stage = jobs.job(_jobKey)?.stage else { return .idle }
			switch stage {
			case .downloading, .paused, .resuming, .importing: return .downloading
			case .signing: return .signing
			default: return .installing
			}
		}
		nonmutating set {
			switch newValue {
			case .idle:
				jobs.finish(_jobKey)
			case .downloading:
				if !jobs.begin(_jobKey, stage: .downloading) { jobs.advance(_jobKey, to: .downloading) }
			case .signing:
				if !jobs.begin(_jobKey, stage: .signing) { jobs.advance(_jobKey, to: .signing) }
			case .installing:
				if !jobs.begin(_jobKey, stage: .packaging) { jobs.advance(_jobKey, to: .packaging) }
			}
		}
	}

	private var installationProgress: Double {
		get {
			guard let job = jobs.job(_jobKey), job.stage.isFinishing else { return 0 }
			return job.progress
		}
		nonmutating set { jobs.setProgress(_jobKey, newValue) }
	}

	private static func _isCancellation(_ error: Error) -> Bool {
		error is ZagInstallCancelled || (error as? ZagMobileDataInstallError) == .cancelled
	}

	/// Committed Imported and Signed records are kept; the row returns to
	/// its normal state.
	private func _finishCancelled() {
		ZagLogger.shared.info("Repository Install", "Cancelled: \(app.currentName) | id=\(app.id ?? "unknown")")
		retrySignedUUID = nil
		retryImportedUUID = nil
		UserDefaults.standard.removeObject(forKey: _retryStorageKey)
		UserDefaults.standard.removeObject(forKey: _signingRetryStorageKey)
		zagPhase = .idle
		actionClaimed = false
	}

	private var pillBackground: Color {
		colorScheme == .dark
			? Color(hex: "#1C1C1E")
			: Color(hex: "#F2F2F7")
	}

	// Resolve the same dynamic accent used by the app's tinted controls.
	// Do not reinterpret an sRGB preference hex string as P3 components.
	@AppStorage("Feather.userTintColor") private var userTintColor: String = "#0090FF"
	private var pillForeground: Color {
		ZagWideGamutTint.color(hex: userTintColor)
	}

	var body: some View {
		ZStack {
			// One control in one place: Get / Install / Update contracts into
			// the progress circle and expands into Open, Resume or back.
			let control = _control
			ZagInstallControl(
				mode: control.mode,
				tint: pillForeground,
				action: control.action,
				cancelAction: _canCancelFromControl ? { _cancelJob(downloadManager.getDownload(by: app.currentUniqueId)) } : nil
			)

			if let caption = _actionCaption {
				Text(caption.text)
					.font(.system(size: 8, weight: .regular))
					.foregroundStyle(caption.color)
					.lineLimit(1)
					.minimumScaleFactor(0.75)
					.frame(width: 88, height: 11)
					.offset(y: 26)
			}
		}
		.frame(width: 88, height: 84, alignment: .center)
		.onAppear {
			_refreshDownloadHistory()
			setupObserver()
			_restoreRetryIfAvailable()
			_restoreSigningRetryIfAvailable()
		}
		.onDisappear { cancellable?.cancel() }
		.alert(.localized("Unable to Install"), isPresented: Binding(
			get: { transactionError != nil },
			set: { if !$0 { transactionError = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(transactionError ?? "")
		}
		.alert("AltStore PAL App", isPresented: $isPALInfoPresented) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text("This app uses Apple's alternative marketplace distribution system and can't be installed directly by Zag Store. You can install it through its supported PAL marketplace, if available in your region.")
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

	private var _isCurrentVariantInstalled: Bool {
        guard let bundleID = app.id else { return false }
        return (installedBundleID == bundleID) ||
            (pairingCore.isInstalled(bundleID: bundleID) &&
             _matchesTrackedVariant(bundleID: bundleID) &&
             _installedReleaseRelationship(bundleID: bundleID) == .same)
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
		if let job = jobs.job(_jobKey) {
			if job.cancelRequested { return .localized("Cancelling…") }
			if job.stage == .paused { return .localized("Paused") }
		}
		switch zagPhase {
		case .downloading: return .localized("Downloading…")
		case .signing: return .localized("Preparing…")
		case .installing: return .localized("Installing…")
		default: return ""
		}
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

    private var _retryStorageKey: String {
        "zagStore.installRetry." + app.currentUniqueId
    }

    private func _restoreRetryIfAvailable() {
        guard retrySignedUUID == nil,
              let uuid = UserDefaults.standard.string(forKey: _retryStorageKey) else { return }
        retrySignedUUID = uuid
        if _retrySignedCopy() == nil {
            retrySignedUUID = nil
            UserDefaults.standard.removeObject(forKey: _retryStorageKey)
        }
    }

    private var _signingRetryStorageKey: String {
        "zagStore.signingRetry." + app.currentUniqueId
    }

    private func _retryImportedCopy() -> Imported? {
        guard let retryImportedUUID,
              let imported = _importedApp(uuid: retryImportedUUID),
              let identifier = imported.identifier,
              identifier == app.id,
              let version = imported.version,
              version == app.currentVersion,
              Storage.shared.getAppDirectory(for: imported) != nil
        else { return nil }
        return imported
    }

    private func _restoreSigningRetryIfAvailable() {
        guard retryImportedUUID == nil,
              let uuid = UserDefaults.standard.string(forKey: _signingRetryStorageKey) else { return }
        retryImportedUUID = uuid
        if _retryImportedCopy() == nil {
            retryImportedUUID = nil
            UserDefaults.standard.removeObject(forKey: _signingRetryStorageKey)
        }
    }

    private func _retrySigning() {
        guard zagPhase == .idle, let imported = _retryImportedCopy() else { return }
        _signAndInstall(imported)
    }

	private func _retrySignedCopy() -> Signed? {
        guard let retrySignedUUID, let signed = _signedApp(uuid: retrySignedUUID) else {
            return nil
        }
        // Never reuse a package belonging to a different repository app or release.
        guard let matching = _existingSignedCopy(),
              matching.objectID == signed.objectID else {
            return nil
        }
        return signed
    }

    private func _retryInstallation() {
        guard zagPhase == .idle, let signed = _retrySignedCopy() else { return }
        zagPhase = .installing
        installationProgress = 0
        _installInline(signed)
    }

	private func _installExistingSignedCopy() {
		guard zagPhase == .idle, let signed = _existingSignedCopy() else { return }
		retrySignedUUID = signed.uuid
		if let uuid = signed.uuid { UserDefaults.standard.set(uuid, forKey: _retryStorageKey) }
		zagPhase = .installing
		installationProgress = 0
		_installInline(signed)
	}

	private func _trackedVariantDecision(bundleID: String) -> ZagVariantLineageResolver.Decision? {
		let defaults = UserDefaults.standard
		let variants = defaults.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]
		guard let trackedVariant = variants[bundleID] else { return nil }
		let appOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		let repositoryOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryOrigins"
		) as? [String: String] ?? [:]
		return UpdateManager.variantLineageDecision(
			for: app,
			in: source,
			trackedVariant: trackedVariant,
			trackedAppName: appOrigins[bundleID],
			trackedRepository: repositoryOrigins[bundleID]
		)
	}

	private func _hasInstalledTrackedAlternative(bundleID: String) -> Bool {
		let defaults = UserDefaults.standard
		guard let decision = _trackedVariantDecision(bundleID: bundleID),
			!decision.isMatch
		else { return false }

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
		if let decision = _trackedVariantDecision(bundleID: bundleID) {
			return decision.isMatch
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

	private func _primaryTap(job: ZagInstallJob?, download: Download?) {
		guard let job else {
			// No job (legacy download): the original tap-to-stop.
			if let download, downloadProgress <= 0.75 { downloadManager.cancelDownload(download) }
			return
		}
		guard !job.cancelRequested else { return }
		if job.stage == .paused { _resume(download); return }
		guard job.stage.isDownload, let download, download.progress < 1 else { return }
		if job.canPause { _pause(download) } else { _cancelJob(download) }
	}

	private func _pause(_ download: Download?) {
		guard let download else { return }
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		let key = _jobKey
		downloadManager.pauseDownload(download) { paused in
			// Without resume data the download reports its own failure.
			if paused { jobs.advance(key, to: .paused) }
		}
	}

	private func _resume(_ download: Download?) {
		guard let download, downloadManager.resumePausedDownload(download) else { return }
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		jobs.advance(_jobKey, to: .resuming)
	}

	private func _cancelJob(_ download: Download?) {
		UIImpactFeedbackGenerator(style: .medium).impactOccurred()
		let response = jobs.requestCancel(_jobKey)
		ZagLogger.shared.info("Repository Install", "Cancel requested: \(app.currentName) | \(response)")
		guard response == .now else { return }
		if let download, download.progress >= 1, !download.isPaused {
			// The bytes are in; importing can't be interrupted. The request
			// is honoured when the import finishes.
			jobs.advance(_jobKey, to: .importing)
			return
		}
		if let download {
			// Stops the transfer, removes its partial file, and reports
			// cancellation through the pipeline callback.
			downloadManager.cancelDownload(download)
		} else {
			zagPhase = .idle
		}
	}

	/// Pause only while transferring from a server that supports genuine
	/// resume; the existing stop square when it can't resume.
	private func _downloadGlyph(_ download: Download) -> ZagInstallGlyph {
		guard let job = jobs.job(_jobKey) else { return downloadProgress <= 0.75 ? .stop : .none }
		if job.cancelRequested { return .none }
		guard job.stage.isDownload, job.stage != .paused, download.progress < 1 else { return .none }
		return job.canPause ? .pause : .stop
	}

	/// VoiceOver can cancel wherever cancellation is genuinely possible.
	private var _canCancelFromControl: Bool {
		guard let job = jobs.job(_jobKey) else { return false }
		return job.offersCancel && job.stage.allowsCancel && !job.cancelRequested
	}

	private func _pill(_ title: String?, image: String? = nil, filled: Bool = true, enabled: Bool = true, label: String) -> ZagInstallControlMode {
		.pill(ZagInstallPill(title: title, systemImage: image, filled: filled, enabled: enabled, accessibilityLabel: label))
	}

	/// The row's action as one mode plus its tap, in the same order as the
	/// previous branches.
	private var _control: (mode: ZagInstallControlMode, action: () -> Void) {
		if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId), currentDownload.canRetry, zagPhase == .idle, !_isPALApp, !_isCurrentVariantInstalled {
			return (_pill(.localized("Retry"), enabled: !actionClaimed, label: "Retry downloading \(app.currentName)"),
					{ _performAction { _startGetAndInstall() } })
		}
		if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) {
			if jobs.job(_jobKey)?.stage == .paused {
				return (_pill(.localized("Resume"), image: "icloud.and.arrow.down", label: "Resume downloading \(app.currentName)"),
						{ _resume(currentDownload) })
			}
			return (.progress(downloadProgress, _downloadGlyph(currentDownload)),
					{ _primaryTap(job: jobs.job(_jobKey), download: currentDownload) })
		}
		switch zagPhase {
		case .downloading, .signing:
			return (.spinner(.none), {})
		case .installing:
			return (installationProgress > 0.03 ? .progress(installationProgress, .none) : .spinner(.none), {})
		case .idle:
			break
		}
		if retrySignedUUID != nil, _retrySignedCopy() != nil {
			return (_pill(.localized("Retry"), enabled: !actionClaimed, label: "Retry installing \(app.currentName)"),
					{ _performAction { _retryInstallation() } })
		}
		if retryImportedUUID != nil, _retryImportedCopy() != nil {
			return (_pill(.localized("Retry"), enabled: !actionClaimed, label: "Retry signing \(app.currentName)"),
					{ _performAction { _retrySigning() } })
		}
		if _isPALApp {
			return (_pill("PAL", label: "About AltStore PAL distribution for \(app.currentName)"),
					{ UIImpactFeedbackGenerator(style: .light).impactOccurred(); isPALInfoPresented = true })
		}
		if let bundleID = app.id, installedBundleID == bundleID {
			return (_pill(.localized("Open"), label: "Open \(app.currentName)"),
					{ _performAction(claim: false) { UIApplication.openApp(with: bundleID) } })
		}
		if let bundleID = app.id, pairingCore.isInstalled(bundleID: bundleID), _matchesTrackedVariant(bundleID: bundleID) {
			switch _installedReleaseRelationship(bundleID: bundleID) {
			case .newer:
				return (_pill(.localized("Update"), enabled: !actionClaimed, label: "Update \(app.currentName)"),
						{ _performAction { _startGetAndInstall() } })
			case .same:
				return (_pill(.localized("Open"), label: "Open \(app.currentName)"),
						{ _performAction(claim: false) { UIApplication.openApp(with: bundleID) } })
			case .older:
				return (_pill(.localized("Revert"), enabled: !actionClaimed, label: "Revert \(app.currentName)"),
						{ _performAction { _startGetAndInstall() } })
			case .unknown:
				return (_pill(.localized("Open"), label: "Open \(app.currentName)"),
						{ UIApplication.openApp(with: bundleID) })
			}
		}
		if let bundleID = app.id, _hasInstalledTrackedAlternative(bundleID: bundleID) {
			return (_pill(.localized("Switch"), enabled: !actionClaimed, label: "Switch to \(app.currentName)"),
					{ _performAction { _startGetAndInstall() } })
		}
		if _hasLocalSignedCopy {
			return (_pill(.localized("Install"), enabled: !actionClaimed, label: "Install \(app.currentName)"),
					{ _performAction { _installExistingSignedCopy() } })
		}
		if wasDownloadedBefore {
			return (_pill(nil, image: "icloud.and.arrow.down", filled: false, enabled: !actionClaimed, label: "Download again: \(app.currentName)"),
					{ _performAction { _startGetAndInstall() } })
		}
		return (_pill(title, enabled: !actionClaimed, label: "\(title) \(app.currentName)"),
				{ _performAction { _startGetAndInstall() } })
	}

	private func _startGetAndInstall() {
		guard !_isPALApp else {
			isPALInfoPresented = true
			return
		}
		guard zagPhase == .idle, let url = app.currentDownloadUrl else { return }

		// Validate installation settings and choose the signing identity before
		// downloading a potentially large IPA.
		Task { @MainActor in
			guard zagPhase == .idle else { return }
                // Installation transport is selected automatically.
			guard let certificate = await ZagCertificateSelection.chooseForSigning() else {
				if Storage.shared.getAllCertificates().isEmpty {
					_failTransaction(.localized("Add a signing certificate before downloading this app."))
				} else {
					zagPhase = .idle
					actionClaimed = false
				}
				return
			}
			guard zagPhase == .idle else { actionClaimed = false; return }
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
								actionClaimed = false
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
						_rememberSuccessfulDownload()
						// Safe point: the import committed; keep it and stop.
						if jobs.isCancelRequested(_jobKey) {
							_finishCancelled()
							return
						}
						retryImportedUUID = uuid
						UserDefaults.standard.set(uuid, forKey: _signingRetryStorageKey)
						_signAndInstall(imported, certificate: certificate)
					}
				}
			)
		}
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
			// Safe point: signing committed the Signed record; keep it and stop.
			if jobs.isCancelRequested(_jobKey) {
				_finishCancelled()
				return
			}
			retryImportedUUID = nil
			UserDefaults.standard.removeObject(forKey: _signingRetryStorageKey)
			retrySignedUUID = signedUUID
			UserDefaults.standard.set(signedUUID, forKey: _retryStorageKey)
			zagPhase = .installing
			installationProgress = 0
			_installInline(signed, imported: imported)
		}
	}

	private func _installInline(_ signed: Signed, imported: Imported? = nil) {
		let method: Int
		if #available(iOS 17.0, *) {
			method = 2 // Native RPPairing
		} else {
			method = 1 // Legacy InstallationProxy
		}
		ZagLogger.shared.info("Installation", "Install started: \(signed.name ?? app.currentName) | id=\(signed.identifier ?? "unknown") | method=\(method)")

		let key = _jobKey
		Task {
			do {
				let status = InstallerStatusViewModel(isIdevice: method == 1)
				let archive = ArchiveHandler(app: signed, viewModel: status)
				try await archive.move()
				let packageURL = try await archive.archive()
				// The package is this job's own temporary file.
				defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
				// Safe point: packaging finished.
				try jobs.checkpoint(key)

				if method == 1 {
					try jobs.beginInstalling(key)
					let proxy = InstallationProxy(viewModel: status)
					try await proxy.install(at: packageURL, suspend: false)
					installationProgress = 1
				} else {
					// Mobile Data Fix wraps the existing installer when Mobile Data blocks it.
					jobs.advance(key, to: .preparingMobileDataFix)
					let coordinator = ZagMobileDataInstallCoordinator.shared
					try await coordinator.install(jobID: signed.uuid ?? UUID().uuidString, cancelRequested: { jobs.isCancelRequested(key) }) {
						// Last safe point; after this the installer must finish.
						try jobs.beginInstalling(key)
						defer { if coordinator.usingMobileDataFix { jobs.advance(key, to: .restoringMobileData) } }
						try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
							do {
								try ZagRPPairingCore.shared.installGate4IPA(
									at: packageURL,
									deviceIP: ZagDeviceLink.peerAddress,
									retryTransientFailures: true,
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
					}
					installationProgress = 1
				}

				retrySignedUUID = nil
				UserDefaults.standard.removeObject(forKey: _retryStorageKey)
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
			} catch where Self._isCancellation(error) {
				_finishCancelled()
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
		actionClaimed = false
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

		let publisher = Publishers.CombineLatest3(
			download.$progress,
			download.$unpackageProgress,
			download.$canPause
		)

		let key = _jobKey
		let jobs = self.jobs
		cancellable = publisher.sink { progress, unpackage, canPause in
			// @Published delivers new values before they are stored.
			let overall = download.onlyArchiving ? unpackage : (0.3 * unpackage) + (0.7 * progress)
			downloadProgress = overall
			jobs.setCanPause(key, canPause)
			jobs.setProgress(key, overall)
			if let stage = jobs.job(key)?.stage {
				if stage == .resuming, !download.isPaused { jobs.advance(key, to: .downloading) }
				if stage == .downloading, progress >= 1 { jobs.advance(key, to: .importing) }
			}
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


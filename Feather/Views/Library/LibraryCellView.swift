//
//  LibraryAppIconView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import CoreData
import NimbleExtensions
import NimbleViews
import NukeUI
import AltSourceKit

// MARK: - View

struct LibraryCellView: View {
	private static let activityDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "d MMM yyyy"
		return formatter
	}()
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared

	private var displayCertificate: CertificatePair? {
		if let certificate = Storage.shared.getCertificate(from: app) {
			return certificate
		}

		let certificates = Storage.shared.getAllCertificates()
		let selectedIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		if certificates.indices.contains(selectedIndex) {
			return certificates[selectedIndex]
		}

		return certificates.first
	}

	var certInfo: Date.ExpirationInfo? {
		displayCertificate?
			.expiration?
			.expirationInfo()
	}

	var certRevoked: Bool {
		displayCertificate?.revoked == true
	}

	var app: AppInfoPresentable
	var isManagedInstalled: Bool = false
	var isRemoving: Bool = false
	var showsSeparator: Bool = true
	var onDeleteApp: ((AppInfoPresentable) -> Void)? = nil
	var onRemoveManagedApp: ((AppInfoPresentable) -> Void)? = nil
	var onRepositoryBadgeTap: ((AltSource) -> Void)? = nil
	var onSignedForInstall: ((String) -> Void)? = nil
	var onInstallCompleted: ((AppInfoPresentable) async -> Bool)? = nil
	var onInstallFailedAfterSigning: ((String) -> Void)? = nil

	@State private var isDeleteConfirmationPresented = false
	@AppStorage(ZagCertificateSelection.allowCustomisationKey)
	private var allowSigningCustomisation = false
	@AppStorage(ZagCertificateSelection.askEveryTimeKey)
	private var askCertificateEveryTime = false
	@State private var isSigningImmediately = false
	@State private var signingRingRotation: Double = 0
	@State private var isInstallingImmediately = false
	@State private var installingRingRotation: Double = 0

	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedInstallAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>

	// MARK: - Selections

	private var _isSelected: Bool {
		guard let uuid = app.uuid else {
			return false
		}
		return selectedAppUUIDs.contains(uuid)
	}

	private func _toggleSelection() {
		guard let uuid = app.uuid else {
			return
		}

		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}

	// MARK: - Body

	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active

		HStack(spacing: 18) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(
						systemName:
							_isSelected
							? "checkmark.circle.fill"
							: "circle"
					)
					.foregroundColor(
						_isSelected
							? .accentColor
							: .secondary
					)
					.font(.title2)
				}
				.buttonStyle(.borderless)
			}

			HStack(spacing: 10) {
				ZStack(alignment: .bottomLeading) {
					FRAppIconView(
						app: app,
						size: 62
					)

					if let repositoryIconURL {
						Button {
							guard let source = repositoryOrigin?.0 else { return }
							UIImpactFeedbackGenerator(style: .light).impactOccurred()
							onRepositoryBadgeTap?(source)
						} label: {
							LazyImage(url: repositoryIconURL) { state in
								if let image = state.image {
									image
										.appIconStyle(
											size: 20,
											isCircle: true,
											background: Color(
												uiColor: .secondarySystemBackground
											)
										)
										.offset(x: 46, y: 4)
								}
							}
						}
						.buttonStyle(.plain)
						.accessibilityLabel(
							Text("\(repositoryOrigin?.1.name ?? "Repository") repository")
						)
						.accessibilityHint(
							Text("Opens this app's source repository")
						)
						.accessibilityAddTraits(.isButton)
					}
				}

				NBTitleWithSubtitleView(
					title:
						app.name ??
						.localized("Unknown"),
					subtitle: _desc,
					linelimit: 0
				)
			}

			Spacer(minLength: 6)

			if !isEditing {
				if isRemoving {
					ProgressView()
						.controlSize(.small)
						.accessibilityLabel(Text(.localized("Removing App")))
				} else {
					_buttonActions(for: app)
				}
			}
		}
		.frame(height: isRegular ? nil : ZagListLayout.compactRowHeight)
		.padding(isRegular ? 12 : 0)
		.overlay(alignment: .bottom) {
			if showsSeparator {
				Rectangle()
					.fill(Color(uiColor: .separator))
					.frame(height: ZagListLayout.separatorHeight)
					.padding(.leading, ZagListLayout.separatorLeadingInset)
			}
		}
		.listRowInsets(
			isRegular
				? EdgeInsets()
				: EdgeInsets(top: 0, leading: ZagListLayout.horizontalInset, bottom: 0, trailing: ZagListLayout.horizontalInset)
		)
		.background(
			isRegular
				? RoundedRectangle(
					cornerRadius: 18,
					style: .continuous
				)
				.fill(
					_isSelected && isEditing
						? Color.accentColor.opacity(0.1)
						: Color(.quaternarySystemFill)
				)
				: nil
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			} else {
				selectedInfoAppPresenting = AnyApp(base: app)
			}
		}
		.swipeActions {
			if !isEditing {
				_swipeActions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)

				if let repositoryName = repositoryOrigin?.1.name {
					Label(
						"Source: \(repositoryName)",
						systemImage: "shippingbox"
					)
					.disabled(true)

					Divider()
				}

				Divider()

				_contextActionsExtra(for: app)

				Divider()

				_actions(for: app)
			}
		}
		.alert(.localized("Delete Stored Copy?"), isPresented: $isDeleteConfirmationPresented) {
			Button(.localized("Delete"), role: .destructive) {
				onDeleteApp?(app)
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(
				String(
					format: .localized("Delete %@ from Zag Store? This removes Zag Store's stored copy, but does not uninstall the app from your iPhone."),
					app.name ?? .localized("this app")
				)
			)
		}

	}

	// MARK: - Repository Origin

	private var repositoryOrigin: (AltSource, ASRepository)? {
		guard let bundleID = app.identifier, !bundleID.isEmpty else {
			return nil
		}

		let origins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryOrigins"
		) as? [String: String]
		let origin = origins?[bundleID]

		if let origin {
			if let match = sourcesViewModel.sources.first(where: { storedSource, repository in
				storedSource.sourceURL?.absoluteString == origin ||
				repository.id == origin ||
				repository.website?.absoluteString == origin ||
				repository.name == origin
			}) {
				return match
			}
		}

		// Repository reconciliation records a unique legacy origin when it is
		// safe to do so. Do not rescan every app in every repository from each
		// visible row; that made scrolling cost grow with the entire catalog.
		return nil
	}

	private var repositoryIconURL: URL? {
		if let iconURL = repositoryOrigin?.1.currentIconURL {
			return iconURL
		}

		guard let bundleID = app.identifier, !bundleID.isEmpty else {
			return nil
		}
		let icons = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryOriginIcons"
		) as? [String: String]
		guard
			let value = icons?[bundleID],
			let url = URL(string: value)
		else {
			return nil
		}
		return url
	}

	// MARK: - Description

	private var _desc: String {
		let version = app.version

		let storedDate: Date?
		if let signed = app as? Signed {
			storedDate = signed.date
		} else if let imported = app as? Imported {
			storedDate = imported.date
		} else {
			storedDate = nil
		}

		guard let storedDate else {
			return version ?? .localized("Unknown")
		}

		let calendar = Calendar.current
		let startOfToday = calendar.startOfDay(for: Date())
		let startOfStoredDate = calendar.startOfDay(for: storedDate)
		let dayDifference = calendar.dateComponents(
			[.day],
			from: startOfStoredDate,
			to: startOfToday
		).day

		let dateText: String
		switch dayDifference {
		case 0:
			dateText = "Today"
		case 1:
			dateText = "Yesterday"
		case 2:
			dateText = "Two Days Ago"
		case 3:
			dateText = "Three Days Ago"
		default:
			dateText = Self.activityDateFormatter.string(from: storedDate)
		}

		if let version, !version.isEmpty {
			return "\(dateText) • \(version)"
		}
		return dateText
	}
}

// MARK: - Actions

extension LibraryCellView {
	@ViewBuilder
	private func _swipeActions(
		for app: AppInfoPresentable
	) -> some View {
		Button {
			isDeleteConfirmationPresented = true
		} label: {
			Label(.localized("Delete"), systemImage: "trash")
		}
		.tint(.red)

		if isManagedInstalled {
			Button {
				onRemoveManagedApp?(app)
			} label: {
				Label(
					isRemoving ? .localized("Removing…") : .localized("Remove App"),
					systemImage: isRemoving ? "hourglass" : "minus.circle"
				)
			}
			.tint(.red)
			.disabled(isRemoving)
		}
	}

	@ViewBuilder
	private func _actions(
		for app: AppInfoPresentable
	) -> some View {
		Button(
			.localized("Delete"),
			systemImage: "trash",
			role: .destructive
		) {
			isDeleteConfirmationPresented = true
		}

		if isManagedInstalled {
			Button(
				isRemoving ? .localized("Removing…") : .localized("Remove App"),
				systemImage: isRemoving ? "hourglass" : "minus.circle",
				role: .destructive
			) {
				onRemoveManagedApp?(app)
			}
			.disabled(isRemoving)
		}
	}

	@ViewBuilder
	private func _contextActions(
		for app: AppInfoPresentable
	) -> some View {
		Button(
			.localized("Get Info"),
			systemImage: "info.circle"
		) {
			selectedInfoAppPresenting = AnyApp(base: app)
		}
	}

	@ViewBuilder
	private func _contextActionsExtra(
		for app: AppInfoPresentable
	) -> some View {
		if app.isSigned {
			if isManagedInstalled, let id = app.identifier {
				Button(
					.localized("Open"),
					systemImage: "app.badge.checkmark"
				) {
					UIApplication.openApp(with: id)
				}
			} else {
				Button(
					.localized("Install"),
					systemImage: "square.and.arrow.down"
				) {
					_installImmediately(app)
				}
			}

			if isManagedInstalled {
				Button(
					.localized("Re-install"),
					systemImage: "square.and.arrow.down"
				) {
					_installImmediately(app)
				}
			}

			Button(
				.localized("Re-sign"),
				systemImage: "signature"
			) {
				selectedSigningAppPresenting = AnyApp(base: app)
			}

			Button(
				.localized("Export"),
				systemImage: "square.and.arrow.up"
			) {
				selectedInstallAppPresenting = AnyApp(
					base: app,
					archive: true
				)
			}
		} else {
			Button(
				.localized("Install"),
				systemImage: "square.and.arrow.down"
			) {
				selectedInstallAppPresenting = AnyApp(base: app)
			}

			Button(
				.localized("Sign"),
				systemImage: "signature"
			) {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		}
	}

	// MARK: - App Store Style Action

	@ViewBuilder
	private func _buttonActions(
		for app: AppInfoPresentable
	) -> some View {
		if app.isSigned {
			ZStack {
				if isManagedInstalled, let id = app.identifier {
					ZagActionPill(title: .localized("Open")) {
						UIApplication.openApp(with: id)
					}
				} else if isInstallingImmediately {
					VStack(spacing: 2) {
						_installingIndeterminateRing()
							.frame(
								width: ZagListLayout.actionWidth,
								height: ZagListLayout.actionHeight
							)

						Text(.localized("Installing..."))
							.font(.system(size: 9, weight: .medium))
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.frame(width: 88, height: 11)
					}
					.transition(.opacity)
				} else {
					ZagActionPill(title: .localized("Install")) {
						_installImmediately(app)
					}
				}

				if !isInstallingImmediately && certRevoked {
					Text(.localized("Revoked"))
						.font(
							.system(
								size: 10,
								weight: .regular
							)
						)
						.foregroundStyle(Color.red)
						.lineLimit(1)
						.offset(y: 24)
				} else if !isInstallingImmediately, let certInfo {
					Text(certInfo.formatted)
						.font(
							.system(
								size: 8,
								weight: .regular
							)
						)
						.foregroundStyle(certInfo.color)
						.lineLimit(1)
						.offset(y: 26)
				}
			}
			.frame(width: ZagListLayout.actionWidth, height: ZagListLayout.compactRowHeight, alignment: .center)
			} else {
				if isSigningImmediately {
					VStack(spacing: 2) {
						_signingIndeterminateRing()
							.frame(width: ZagListLayout.actionWidth, height: ZagListLayout.actionHeight)

						Text(.localized("Signing..."))
							.font(.system(size: 9, weight: .medium))
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.frame(width: 88, height: 11)
					}
					.transition(.opacity)
				} else if isInstallingImmediately {
					VStack(spacing: 2) {
						_installingIndeterminateRing()
							.frame(width: ZagListLayout.actionWidth, height: ZagListLayout.actionHeight)

						Text(.localized("Installing..."))
							.font(.system(size: 9, weight: .medium))
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.frame(width: 88, height: 11)
					}
					.transition(.opacity)
				} else {
					ZagActionPill(title: .localized("Sign")) {
						if askCertificateEveryTime {
							selectedSigningAppPresenting = AnyApp(base: app)
						} else {
							_signImmediately(app)
						}
					}
				}
			}
	}

	private func _signingIndeterminateRing() -> some View {
		ZStack {
			Circle()
				.stroke(Color.accentColor.opacity(0.22), lineWidth: 2.3)
			Circle()
				.trim(from: 0.08, to: 0.72)
				.stroke(
					Color.accentColor,
					style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
				)
				.rotationEffect(.degrees(signingRingRotation - 90))
		}
		.frame(width: 31, height: 31)
		.onAppear {
			signingRingRotation = 0
			withAnimation(
				.linear(duration: 0.85)
					.repeatForever(autoreverses: false)
			) {
				signingRingRotation = 360
			}
		}
	}

	private func _installingIndeterminateRing() -> some View {
		ZStack {
			Circle()
				.stroke(Color.accentColor.opacity(0.22), lineWidth: 2.3)
			Circle()
				.trim(from: 0.08, to: 0.72)
				.stroke(
					Color.accentColor,
					style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
				)
				.rotationEffect(.degrees(installingRingRotation - 90))
		}
		.frame(width: 31, height: 31)
		.onAppear {
			installingRingRotation = 0
			withAnimation(
				.linear(duration: 0.85)
					.repeatForever(autoreverses: false)
			) {
				installingRingRotation = 360
			}
		}
	}

	private func _installImmediately(
		_ app: AppInfoPresentable,
		importedAfterSigning: AppInfoPresentable? = nil
	) {
		// In a Sign -> Install transaction the signing stage has already
		// switched this row into its Installing... state.
		if importedAfterSigning == nil {
			guard !isInstallingImmediately else { return }

			withAnimation(.easeInOut(duration: 0.25)) {
				isInstallingImmediately = true
			}
		}

		UIImpactFeedbackGenerator(style: .light).impactOccurred()

		Task { @MainActor in
			do {
				let archiveHandler = ArchiveHandler(app: app)
				try await archiveHandler.move()
				let packageURL = try await archiveHandler.archive()

				defer {
					try? FileManager.default.removeItem(
						at: packageURL.deletingLastPathComponent()
					)
				}

				try await withCheckedThrowingContinuation {
					(continuation: CheckedContinuation<Void, Error>) in

					do {
						try ZagRPPairingCore.shared.installGate4IPA(
							at: packageURL,
							deviceIP: "10.7.0.1",
							completion: { result in
								continuation.resume(with: result)
							}
						)
					} catch {
						continuation.resume(throwing: error)
					}
				}

				let confirmed = await onInstallCompleted?(app) ?? false

				if confirmed {
					try? await Task.sleep(nanoseconds: 550_000_000)

					withAnimation(.easeInOut(duration: 0.35)) {
						isInstallingImmediately = false

						if let importedAfterSigning {
							Storage.shared.deleteApp(for: importedAfterSigning)
						}
					}
				} else {
					withAnimation(.easeInOut(duration: 0.25)) {
						isInstallingImmediately = false
					}

					if let importedAfterSigning {
						Storage.shared.deleteApp(for: importedAfterSigning)
					}
				}
			} catch {
				withAnimation(.easeInOut(duration: 0.25)) {
					isInstallingImmediately = false
				}

				// Signing succeeded but installation did not. Remove the
				// Imported staging row and leave the Signed result available
				// so installation can be retried from Signed.
				if let importedAfterSigning {
					if let signedUUID = app.uuid {
						onInstallFailedAfterSigning?(signedUUID)
					}
					Storage.shared.deleteApp(for: importedAfterSigning)
				}

				UIAlertController.showAlertWithOk(
					title: .localized("Installation Failed"),
					message: error.localizedDescription,
					isCancel: true
				)
			}
		}
	}

	private func _signImmediately(_ app: AppInfoPresentable) {
		guard !isSigningImmediately, !isInstallingImmediately else { return }

		withAnimation(.easeInOut(duration: 0.25)) {
			isSigningImmediately = true
		}

		Task { @MainActor in
			guard let certificate = await ZagCertificateSelection.chooseForSigning() else {
				withAnimation(.easeInOut(duration: 0.25)) {
					isSigningImmediately = false
				}
				if Storage.shared.getAllCertificates().isEmpty {
					UIAlertController.showAlertWithOk(
						title: .localized("No Certificate"),
						message: .localized("Please go to settings and import a valid certificate"),
						isCancel: true
					)
				}
				return
			}

			var options = OptionsManager.shared.options

			if
				options.ppqProtection,
				let identifier = app.identifier,
				certificate.ppQCheck
			{
				options.appIdentifier = "\(identifier).\(options.ppqString)"
			}
			if
				let identifier = app.identifier,
				let mappedIdentifier = options.identifiers[identifier]
			{
				options.appIdentifier = mappedIdentifier
			}
			if
				let name = app.name,
				let mappedName = options.displayNames[name]
			{
				options.appName = mappedName
			}

			UIImpactFeedbackGenerator(style: .light).impactOccurred()

			var signedUUID: String?

			FR.signPackageFile(
				app,
				using: options,
				icon: nil,
				certificate: certificate,
				signedUUID: { signedUUID = $0 }
			) { error in
				if let error {
					withAnimation(.easeInOut(duration: 0.25)) {
						isSigningImmediately = false
					}

					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: error.localizedDescription,
						isCancel: true
					)
					return
				}

				guard !app.isSigned else {
					withAnimation(.easeInOut(duration: 0.25)) {
						isSigningImmediately = false
					}
					return
				}

				if options.post_installAppAfterSigned {
					guard
						let signedUUID,
						let signed = _signedApp(uuid: signedUUID)
					else {
						withAnimation(.easeInOut(duration: 0.25)) {
							isSigningImmediately = false
						}

						UIAlertController.showAlertWithOk(
							title: .localized("Installation Failed"),
							message: .localized("Signing completed, but Zag Store could not locate the signed app."),
							isCancel: true
						)
						return
					}

					onSignedForInstall?(signedUUID)

					// Keep the Imported row in place. Only its operational
					// state changes from Signing... to Installing...
					withAnimation(.easeInOut(duration: 0.25)) {
						isSigningImmediately = false
						isInstallingImmediately = true
					}

					_installImmediately(
						signed,
						importedAfterSigning: app
					)
				} else {
					withAnimation(.easeInOut(duration: 0.25)) {
						isSigningImmediately = false
					}

					if options.post_deleteAppAfterSigned {
						Storage.shared.deleteApp(for: app)
					}
				}
			}
		}
	}

	private func _signedApp(uuid: String) -> Signed? {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? Storage.shared.context.fetch(request).first
	}

}


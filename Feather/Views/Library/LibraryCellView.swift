//
//  LibraryAppIconView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews
import NukeUI
import AltSourceKit

// MARK: - View

struct LibraryCellView: View {
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
	var onDeleteApp: ((AppInfoPresentable) -> Void)? = nil
	var onRemoveManagedApp: ((AppInfoPresentable) -> Void)? = nil
	var onRepositoryBadgeTap: ((AltSource) -> Void)? = nil

	@State private var isDeleteConfirmationPresented = false
	@AppStorage(ZagCertificateSelection.allowCustomisationKey)
	private var allowSigningCustomisation = false
	@AppStorage(ZagCertificateSelection.askEveryTimeKey)
	private var askCertificateEveryTime = false
	@State private var isSigningImmediately = false
	@State private var signingRingRotation: Double = 0

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
		.padding(isRegular ? 12 : 0)
		.zagAppStoreRowSeparator()
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

		let matches = sourcesViewModel.sources.filter { _, repository in
			repository.apps.contains { $0.id == bundleID }
		}
		return origin == nil && matches.count == 1 ? matches.first : nil
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
			let formatter = DateFormatter()
			formatter.dateFormat = "d MMM yyyy"
			dateText = formatter.string(from: storedDate)
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
					selectedInstallAppPresenting = AnyApp(base: app)
				}
			}

			if isManagedInstalled {
				Button(
					.localized("Re-install"),
					systemImage: "square.and.arrow.down"
				) {
					selectedInstallAppPresenting = AnyApp(base: app)
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
			VStack(
				alignment: .center,
				spacing: 3
			) {
				if isManagedInstalled, let id = app.identifier {
					ZagActionPill(title: .localized("Open")) {
						UIApplication.openApp(with: id)
					}
				} else {
					ZagActionPill(title: .localized("Install")) {
						selectedInstallAppPresenting = AnyApp(base: app)
					}
				}

				if certRevoked {
					Text(.localized("Revoked"))
						.font(
							.system(
								size: 10,
								weight: .regular
							)
						)
						.foregroundStyle(Color.red)
						.lineLimit(1)
						.padding(.top, 1)
				} else if let certInfo {
					Text(certInfo.formatted)
						.font(
							.system(
								size: 10,
								weight: .regular
							)
						)
						.foregroundStyle(certInfo.color)
						.lineLimit(1)
						.padding(.top, 1)
				}
			}
		} else {
			if isSigningImmediately && !allowSigningCustomisation && !askCertificateEveryTime {
				VStack(spacing: 2) {
					_signingIndeterminateRing()
						.frame(width: 88, height: 34)

					Text(.localized("Signing..."))
						.font(.system(size: 9, weight: .medium))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.frame(width: 88, height: 11)
				}
				.transition(.opacity)
			} else {
				ZagActionPill(title: .localized("Sign")) {
					if allowSigningCustomisation {
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

	private func _signImmediately(_ app: AppInfoPresentable) {
		if !allowSigningCustomisation && !askCertificateEveryTime {
			withAnimation(.easeInOut(duration: 0.25)) {
				isSigningImmediately = true
			}
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
			FR.signPackageFile(
				app,
				using: options,
				icon: nil,
				certificate: certificate
			) { error in
				withAnimation(.easeInOut(duration: 0.25)) {
					isSigningImmediately = false
				}

				if let error {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: error.localizedDescription,
						isCancel: true
					)
				} else if !app.isSigned {
					// Seamless Sign is a move from Imported -> Signed.
					// FR has already persisted the Signed record at this point;
					// only now is it safe to remove the original Imported copy.
					Storage.shared.deleteApp(for: app)
				}
			}
		}
	}

}


//
//  LibraryAppIconView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View

struct LibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode

	var certInfo: Date.ExpirationInfo? {
		Storage.shared
			.getCertificate(from: app)?
			.expiration?
			.expirationInfo()
	}

	var certRevoked: Bool {
		Storage.shared
			.getCertificate(from: app)?
			.revoked == true
	}

	var app: AppInfoPresentable
	var isManagedInstalled: Bool = false
	var isRemoving: Bool = false
	var onDeleteApp: ((AppInfoPresentable) -> Void)? = nil
	var onRemoveManagedApp: ((AppInfoPresentable) -> Void)? = nil

	@State private var isDeleteConfirmationPresented = false
	@State private var isRemoveConfirmationPresented = false

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
				FRAppIconView(
					app: app,
					size: 62
				)

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
			}
		}
		.swipeActions {
			if !isEditing {
				_actions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)

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
		.confirmationDialog(
			String(
				format: .localized("Remove “%@”?"),
				app.name ?? .localized("this app")
			),
			isPresented: $isRemoveConfirmationPresented,
			titleVisibility: .visible
		) {
			Button(.localized("Delete App"), role: .destructive) {
				onRemoveManagedApp?(app)
			}
			Button(.localized("Cancel")) {
				isRemoveConfirmationPresented = false
			}
		} message: {
			Text(.localized("This will uninstall the app from your iPhone. Its stored copy will remain in Zag Store so you can install it again later."))
		}
	}

	// MARK: - Description

	private var _desc: String {
		if
			let version = app.version,
			let id = app.identifier
		{
			return "\(version) • \(id)"
		} else {
			return .localized("Unknown")
		}
	}
}

// MARK: - Actions

extension LibraryCellView {
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
				isRemoveConfirmationPresented = true
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
								size: 11,
								weight: .medium
							)
						)
						.foregroundStyle(Color.red)
						.lineLimit(1)
						.padding(.top, 4)
				} else if let certInfo {
					Text(certInfo.formatted)
						.font(
							.system(
								size: 11,
								weight: .medium
							)
						)
						.foregroundStyle(certInfo.color)
						.lineLimit(1)
						.padding(.top, 4)
				}
			}
		} else {
			ZagActionPill(title: .localized("Sign")) {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		}
	}
}


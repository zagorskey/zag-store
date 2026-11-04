import SwiftUI
import NimbleViews

/// Installation Settings row for the Mobile Data Fix.
struct ZagMobileDataFixRow: View {
	@ObservedObject private var controller = ZagMobileDataToggleController.shared

	var body: some View {
		let status = controller.status
		NavigationLink {
			ZagMobileDataFixView()
				.zagSettingsDestinationAvatar()
		} label: {
			HStack(spacing: 12) {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text(status.isVerified ? "Mobile Data Fix" : ZagMobileDataToggle.setupActionTitle)
						if case .notSetUp = status {
							Text("Set up cellular installation support")
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				} icon: {
					Image(systemName: "antenna.radiowaves.left.and.right")
				}
				Spacer(minLength: 8)
				if case .notSetUp = status {
					EmptyView()
				} else {
					ZagMobileDataFixStatusLabel(status: status)
						.font(.subheadline)
				}
			}
		}
	}
}

struct ZagMobileDataFixStatusLabel: View {
	let status: ZagMobileDataToggle.Status

	var body: some View {
		let style = Self.style(for: status)
		Label(status.title, systemImage: style.icon)
			.foregroundStyle(style.color)
			.labelStyle(.titleAndIcon)
	}

	static func style(for status: ZagMobileDataToggle.Status) -> (icon: String, color: Color) {
		switch status {
		case .verified: return ("checkmark.circle.fill", .green)
		case .notSetUp: return ("circle", .secondary)
		case .verificationRequired: return ("questionmark.circle.fill", .orange)
		case .failed: return ("exclamationmark.circle.fill", .red)
		case .updateRequired: return ("arrow.down.circle.fill", .orange)
		}
	}
}

/// Setup and verification for the "Zag Mobile Data Toggle" Shortcut.
struct ZagMobileDataFixView: View {
	@AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
	@ObservedObject private var controller = ZagMobileDataToggleController.shared
	@StateObject private var pairingCore = ZagRPPairingCore.shared

	var body: some View {
		let status = controller.status
		NBList(status.isVerified ? "Mobile Data Fix" : ZagMobileDataToggle.setupActionTitle) {
			Section {
				HStack {
					Text("Status")
					Spacer()
					ZagMobileDataFixStatusLabel(status: status)
				}
				if case .verified(_, let at) = status {
					// Absolute date and time in the device's locale, calendar and
					// time zone. Stacks when it doesn't fit on one line.
					let verified = at.formatted(date: .abbreviated, time: .shortened)
					ViewThatFits(in: .horizontal) {
						HStack {
							Text("Last Verified")
							Spacer()
							Text(verified).foregroundStyle(.secondary)
						}
						.lineLimit(1)
						VStack(alignment: .leading, spacing: 2) {
							Text("Last Verified")
							Text(verified).foregroundStyle(.secondary)
						}
					}
				}
				if let detail = Self.detail(for: status) {
					Text(detail)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} footer: {
				Text("Over Mobile Data, iOS blocks the connection Zag Store uses to install apps. \(ZagMobileDataToggle.shortcutName) temporarily turns Mobile Data off during installation and allows it to be restored afterwards. Shortcuts opens briefly each time, and it only runs when you tap.")
			}

			Section {
				Button {
					controller.openSetupPage()
				} label: {
					Label(status == .notSetUp || Self.needsShortcut(status) ? "Get \(ZagMobileDataToggle.shortcutName)" : "View Setup Page", systemImage: "safari")
				}

				Button {
					controller.verify()
				} label: {
					HStack {
						Label(controller.activity == .waiting(.status) ? "Verifying…" : "Verify Shortcut", systemImage: "checkmark.shield")
						if controller.activity == .waiting(.status) {
							Spacer()
							ProgressView()
						}
					}
				}
				.disabled(controller.isBusy || pairingCore.isGate2Running)

				if controller.isBusy {
					Button("Cancel", role: .cancel) { controller.cancel() }
				}

				if let message = controller.lastMessage {
					Text(message)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Setup")
			} footer: {
				Text("Add the Shortcut from zagstore.app, keep its name \"\(ZagMobileDataToggle.shortcutName)\", then return here and tap Verify. Verifying never changes Mobile Data.")
			}
		}
		.tint(Color(hex: themeColorHex))
	}

	static func needsShortcut(_ status: ZagMobileDataToggle.Status) -> Bool {
		switch status {
		case .failed, .updateRequired: return true
		default: return false
		}
	}

	static func detail(for status: ZagMobileDataToggle.Status) -> String? {
		switch status {
		case .notSetUp: return nil
		case .verificationRequired(let reason): return reason
		case .verified: return "\(ZagMobileDataToggle.shortcutName) replied with the expected protocol (v\(ZagMobileDataToggle.protocolVersion))."
		case .failed(let reason): return reason
		case .updateRequired: return ZagMobileDataToggle.message(for: .incompatible(found: Self.foundVersion(status)))
		}
	}

	private static func foundVersion(_ status: ZagMobileDataToggle.Status) -> Int {
		if case .updateRequired(let found) = status { return found }
		return ZagMobileDataToggle.protocolVersion
	}
}

import SwiftUI

/// Settings › Privacy: the first-launch report setting (off by default).
/// Shown only while ZagFirstLaunchReporter.featureEnabled is true.
struct ZagFirstLaunchPrivacyView: View {
	@AppStorage(ZagFirstLaunchReporter.consentKey) private var _consent = false
	@State private var _status = ZagFirstLaunchReporter.status()

	var body: some View {
		Form {
			Section {
				Toggle(isOn: Binding(
					get: { _consent },
					set: { ZagFirstLaunchReporter.setConsent($0); _status = ZagFirstLaunchReporter.status() }
				)) {
					Text("Share First-Launch Report")
				}
				.toggleStyle(ZagThemeTintToggleStyle())
				.disabled(_status == .notApplicable)
			} footer: {
				Text(ZagFirstLaunchDisclosure.summary)
			}

			Section {
				LabeledContent("Status", value: _statusText)
			} footer: {
				Text(_statusFooter)
			}

			if let marker = ZagFirstLaunchReporter.testBuildMarker {
				Section {
					Text("Test build for the preview acceptance. Not for release.")
				} footer: {
					Text(marker)
				}
			}

			Section {
				ForEach(ZagFirstLaunchDisclosure.sent, id: \.self) { Label($0, systemImage: "arrow.up.circle") }
			} header: {
				Text("Sent Once")
			}

			Section {
				ForEach(ZagFirstLaunchDisclosure.neverSent, id: \.self) { Label($0, systemImage: "xmark.circle") }
			} header: {
				Text("Never Sent")
			} footer: {
				Text(ZagFirstLaunchDisclosure.limits)
			}
		}
		.navigationTitle("Privacy")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear { _status = ZagFirstLaunchReporter.status() }
	}

	private var _statusText: String {
		switch _status {
		case .notApplicable: return "Nothing to Report"
		case .off: return "Off"
		case .pending: return "Waiting to Send"
		case .sent: return "Sent"
		case .stopped: return "Not Sent"
		}
	}

	private var _statusFooter: String {
		switch _status {
		case .notApplicable:
			return "This copy of Zag Store was not signed on the Zag Store website, so it has no report to send."
		case .off:
			return "Nothing is sent while this is off."
		case .pending:
			return "The report is sent the next time a network connection is available. Turning this off stops it."
		case .sent:
			return "The report has been sent. It is never sent again, and turning this off changes nothing already sent."
		case .stopped:
			return "The report could not be delivered and will not be retried."
		}
	}
}

/// The one-time first-launch disclosure: what is asked, in plain words, with
/// two equal choices. Not answering counts as "Don't Share".
struct ZagFirstLaunchDisclosure: View {
	let onChoice: (Bool) -> Void

	static let summary = "Lets Zag Store tell the website, once, that the copy you installed from it has opened. It helps count how many website installations actually start. It is off unless you turn it on."
	static let sent = [
		"The installation code from your download (it identifies that download, not you or your device)",
		"Zag Store version and build",
		"iOS or iPadOS version",
		"Device model type, such as iPhone17,1",
	]
	static let neverSent = [
		"Your name, Apple Account or contacts",
		"Device identifiers or advertising identifiers",
		"Location",
		"Which apps you install or use",
	]
	static let limits = "Sent once over an encrypted connection. The server stores the report without your IP address. It does not identify you, and anyone with a copy of the same download could send the same code."

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					Image(systemName: "checkmark.shield")
						.font(.system(size: 44, weight: .regular))
						.foregroundStyle(.tint)
						.accessibilityHidden(true)
					Text("Help Count Website Installations?")
						.font(.title2.bold())
					Text(Self.summary)
					VStack(alignment: .leading, spacing: 8) {
						Text("Sent once").font(.headline)
						ForEach(Self.sent, id: \.self) { Label($0, systemImage: "arrow.up.circle") }
					}
					VStack(alignment: .leading, spacing: 8) {
						Text("Never sent").font(.headline)
						ForEach(Self.neverSent, id: \.self) { Label($0, systemImage: "xmark.circle") }
					}
					Text(Self.limits).font(.footnote).foregroundStyle(.secondary)
					Text("You can change this at any time in Settings › Privacy.")
						.font(.footnote).foregroundStyle(.secondary)
				}
				.padding(24)
			}
			.safeAreaInset(edge: .bottom) {
				// Equal weight: neither choice is the highlighted default.
				HStack(spacing: 12) {
					Button { onChoice(false) } label: {
						Text("Don't Share").frame(maxWidth: .infinity)
					}
					Button { onChoice(true) } label: {
						Text("Share Once").frame(maxWidth: .infinity)
					}
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
				.padding(.horizontal, 24)
				.padding(.vertical, 12)
				.background(.bar)
			}
		}
	}
}

/// Presents the disclosure once, after the launch splash has finished, and
/// only when the feature is on and this copy has something to report.
struct ZagFirstLaunchDisclosurePresenter: ViewModifier {
	@State private var _presented = false

	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default.publisher(for: .zagLaunchSplashVisibilityDidChange)) { note in
				guard (note.userInfo?["visible"] as? Bool) == false else { return }
				_presentIfNeeded()
			}
			.onAppear {
				if ZagLaunchGate.shared.isFinished { _presentIfNeeded() }
			}
			.sheet(isPresented: $_presented, onDismiss: {
				// Swiped away without a choice: the same as "Don't Share".
				if !UserDefaults.standard.bool(forKey: ZagFirstLaunchReporter.disclosureShownKey) {
					ZagFirstLaunchReporter.setConsent(false)
				}
			}) {
				ZagFirstLaunchDisclosure { allowed in
					ZagFirstLaunchReporter.setConsent(allowed)
					_presented = false
				}
			}
	}

	private func _presentIfNeeded() {
		if ZagFirstLaunchReporter.shouldPresentDisclosure { _presented = true }
	}
}

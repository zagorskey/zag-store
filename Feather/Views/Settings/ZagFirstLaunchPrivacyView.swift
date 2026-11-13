import SwiftUI

/// Settings › Privacy: the first-launch report setting (on by default).
/// Shown only in copies that have a report (ZagFirstLaunchReporter.hasReport).
struct ZagFirstLaunchPrivacyView: View {
	@AppStorage(ZagFirstLaunchReporter.optOutKey) private var _optedOut = false
	@AppStorage(ZagFirstLaunchReporter.jailbreakOptInKey) private var _sharesJailbreak = false
	@State private var _status = ZagFirstLaunchReporter.status()

	var body: some View {
		Form {
			Section {
				Toggle(isOn: Binding(
					get: { !_optedOut },
					set: { ZagFirstLaunchReporter.setSharing($0); _status = ZagFirstLaunchReporter.status() }
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

			Section {
				Toggle(isOn: Binding(
					get: { _sharesJailbreak },
					set: { ZagFirstLaunchReporter.setJailbreakSharing($0) }
				)) {
					Text("Share Jailbreak Status")
				}
				.toggleStyle(ZagThemeTintToggleStyle())
				.disabled(_status == .notApplicable || _optedOut)
			} footer: {
				Text(ZagFirstLaunchDisclosure.jailbreak)
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
			return "The report is sent shortly after Zag Store opens with a network connection. Turning this off stops it."
		case .sent:
			return "The report has been sent. It is never sent again, and turning this off changes nothing already sent."
		case .stopped:
			return "The report could not be delivered and will not be retried."
		}
	}
}

/// What the first-launch report contains, in plain words.
enum ZagFirstLaunchDisclosure {
	static let summary = "Zag Store tells the preview website, once, that the copy you installed from it has opened. It helps count how many website installations actually start. Turn this off and nothing is sent."
	static let sent = [
		"The installation code from your download (it identifies that download, not you or your device)",
		"Zag Store version and build",
		"iOS or iPadOS version and build, such as 26.1 (23B85)",
		"Device model type, such as iPhone17,1",
	]
	static let neverSent = [
		"Your name, Apple Account or contacts",
		"Device identifiers or advertising identifiers",
		"Location",
		"Which apps you install or use",
	]
	static let jailbreak = "Off unless you turn it on. When on, Zag Store sends once whether this device appears jailbroken (yes, no or unknown, and rootless or rootful), never which files, tweaks or apps it found. The website only publishes weekly totals of at least 10 devices, and deletes each individual result within 30 days."
	static let limits = "Sent once over an encrypted connection. The server stores the report without your IP address. It does not identify you, and anyone with a copy of the same download could send the same code."
}

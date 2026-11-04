import SwiftUI

/// The App Store-style install control used by repository rows, Library
/// rows and App Updates rows. The row always shows this view in the same
/// place and only changes its `mode`; ZagInstallControlBody morphs between
/// pill and circle around the slot's fixed centre.
struct ZagInstallControl: View {
	let mode: ZagInstallControlMode
	var tint: Color? = nil
	var fill: Color? = nil
	let action: () -> Void
	/// Exposed to VoiceOver as a custom action when cancellation is possible.
	var cancelAction: (() -> Void)? = nil

	@AppStorage("Feather.userTintColor") private var tintHex: String = "#3F8EF7"
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		ZagInstallControlBody(
			mode: mode,
			tint: tint ?? ZagWideGamutTint.color(hex: tintHex),
			fill: fill ?? (colorScheme == .dark ? Color(hex: "#1C1C1E") : Color(hex: "#EEEEF0")),
			action: action
		)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(_accessibilityLabel))
		.accessibilityAddTraits(.isButton)
		.modifier(CancelAccessibility(cancel: cancelAction))
		.onAppear { ZagMainThreadStallMonitor.shared.start() }
	}

	private var _accessibilityLabel: String {
		switch mode {
		case .pill(let pill): return pill.accessibilityLabel
		case .progress(let value, let glyph):
			let percent = "\(Int((min(1, max(0, value)) * 100).rounded())) percent"
			switch glyph {
			case .pause: return "Downloading, \(percent). Pause"
			case .stop: return "Downloading, \(percent). Stop"
			case .none: return "Installing, \(percent)"
			}
		case .spinner: return "Preparing installation"
		}
	}
}

private struct CancelAccessibility: ViewModifier {
	let cancel: (() -> Void)?

	func body(content: Content) -> some View {
		if let cancel {
			content.accessibilityAction(named: Text("Cancel Installation"), cancel)
		} else {
			content
		}
	}
}

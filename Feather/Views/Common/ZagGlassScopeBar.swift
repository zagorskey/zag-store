import SwiftUI
import UIKit

/// The system segmented control styled like the Apps page's search scope
/// bar on device: 32 points tall, 15-point white labels, a dark grey track
/// and a near-black selected segment.
///
/// Being the real UISegmentedControl, it keeps the native behaviour of
/// holding a finger on the selection and sliding it to another segment. It
/// hosts no hidden search bar, so nothing UIKit does while a page scrolls
/// can move it.
struct ZagGlassScopeBar: View {
	@Binding var selection: String
	let titles: [String]

	@Environment(\.colorScheme) private var colorScheme

	static let height: CGFloat = 32

	var body: some View {
		ZagSegmentedControl(selection: $selection, titles: titles)
			.frame(height: Self.height)
			.background { track }
	}

	/// Measured on the Apps page's scope bar on device: a (32, 32, 32)
	/// track in dark, with a faint glass rim.
	private var track: some View {
		Capsule(style: .continuous)
			.fill(Color(uiColor: ZagScopeColors.track))
			.overlay {
				Capsule(style: .continuous)
					.strokeBorder(
						LinearGradient(
							colors: [
								Color.white.opacity(colorScheme == .dark ? 0.14 : 0.7),
								Color.white.opacity(colorScheme == .dark ? 0.04 : 0.2)
							],
							startPoint: .top,
							endPoint: .bottom
						),
						lineWidth: 1
					)
			}
	}
}

/// The scope bar's colours, from the native one on device.
enum ZagScopeColors {
	static let track = UIColor { traits in
		traits.userInterfaceStyle == .dark
			? UIColor(white: 32 / 255, alpha: 1)
			: UIColor(red: 229 / 255, green: 229 / 255, blue: 234 / 255, alpha: 1)
	}
	/// The selected segment: darker than the track in dark, white in light.
	static let selected = UIColor { traits in
		traits.userInterfaceStyle == .dark
			? UIColor(white: 12 / 255, alpha: 1)
			: UIColor.white
	}
}

private struct ZagSegmentedControl: UIViewRepresentable {
	@Binding var selection: String
	let titles: [String]

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeUIView(context: Context) -> UISegmentedControl {
		let control = UISegmentedControl(items: titles)
		// The glass capsule behind is the track; a near-clear colour hides
		// the control's own grey track but keeps the whole width touchable.
		control.backgroundColor = UIColor(white: 0, alpha: 0.001)
		control.selectedSegmentTintColor = ZagScopeColors.selected
		let font = UIFont.systemFont(ofSize: 15, weight: .medium)
		control.setTitleTextAttributes([.font: font, .foregroundColor: UIColor.label], for: .normal)
		control.setTitleTextAttributes([.font: font, .foregroundColor: UIColor.label], for: .selected)
		control.selectedSegmentIndex = titles.firstIndex(of: selection) ?? 0
		control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
		control.setContentHuggingPriority(.defaultLow, for: .horizontal)
		control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		return control
	}

	func updateUIView(_ control: UISegmentedControl, context: Context) {
		context.coordinator.parent = self
		let index = titles.firstIndex(of: selection) ?? 0
		if control.selectedSegmentIndex != index {
			control.selectedSegmentIndex = index
		}
	}

	final class Coordinator: NSObject {
		var parent: ZagSegmentedControl

		init(_ parent: ZagSegmentedControl) {
			self.parent = parent
		}

		@objc func changed(_ control: UISegmentedControl) {
			let index = control.selectedSegmentIndex
			guard parent.titles.indices.contains(index) else { return }
			withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
				parent.selection = parent.titles[index]
			}
		}
	}
}

import SwiftUI
import UIKit

/// The system segmented control on a Liquid Glass capsule, styled like the
/// scope bar iOS 26 shows under a focused search field: 32 points tall,
/// 15-point labels and the same selected fill in light and dark.
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

	@ViewBuilder
	private var track: some View {
		if #available(iOS 26.0, *) {
			Color.clear.glassEffect(.regular, in: Capsule(style: .continuous))
		} else {
			Capsule(style: .continuous)
				.fill(.ultraThinMaterial)
				.overlay {
					Capsule(style: .continuous)
						.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.06), lineWidth: 1)
				}
		}
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
		// Measured on the native scope bar: (54, 54, 54) dark, (229, 229, 233) light.
		control.selectedSegmentTintColor = UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(white: 54 / 255, alpha: 1)
				: UIColor(red: 229 / 255, green: 229 / 255, blue: 233 / 255, alpha: 1)
		}
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

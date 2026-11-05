import SwiftUI

/// A scope switcher drawn in SwiftUI, matching the scope bar iOS 26 shows
/// under a focused search field (measured on a native searchable list): a
/// 32-point glass capsule, a 24-point selected capsule inset 4 points that
/// slides between segments, and 15-point labels.
///
/// Unlike ZagScopeBar it hosts no hidden search bar, so nothing UIKit does
/// while a page scrolls can move it.
struct ZagGlassScopeBar: View {
	@Binding var selection: String
	let titles: [String]

	@Environment(\.colorScheme) private var colorScheme
	@Namespace private var namespace

	static let height: CGFloat = 32
	private static let inset: CGFloat = 4
	/// Between the selected capsule and the neighbouring segment's edge.
	private static let segmentGap: CGFloat = 6

	var body: some View {
		HStack(spacing: Self.segmentGap) {
			ForEach(titles, id: \.self) { title in
				segment(title)
			}
		}
		.padding(Self.inset)
		.frame(height: Self.height)
		.background { track }
		.accessibilityElement(children: .contain)
	}

	private func segment(_ title: String) -> some View {
		let isSelected = selection == title
		return Button {
			guard !isSelected else { return }
			withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
				selection = title
			}
		} label: {
			Text(title)
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(.primary)
				.lineLimit(1)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background {
					if isSelected {
						Capsule(style: .continuous)
							.fill(selectedFill)
							.matchedGeometryEffect(id: "selection", in: namespace)
					}
				}
				.contentShape(Capsule(style: .continuous))
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(isSelected ? [.isSelected] : [])
	}

	/// The selected capsule: (54, 54, 54) in dark, (229, 229, 233) in light.
	private var selectedFill: Color {
		colorScheme == .dark
			? Color(red: 54 / 255, green: 54 / 255, blue: 54 / 255)
			: Color(red: 229 / 255, green: 229 / 255, blue: 233 / 255)
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

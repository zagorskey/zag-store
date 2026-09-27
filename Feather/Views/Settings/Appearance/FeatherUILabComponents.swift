import SwiftUI

struct FeatherLabCountBadge: View {
	@AppStorage("petar.uiLab.badgeSize")
	private var badgeSize: Double = 22

	@AppStorage("petar.uiLab.badgeFontSize")
	private var badgeFontSize: Double = 14

	@AppStorage("petar.uiLab.badgeColor")
	private var badgeColorHex: String = "#FF3B30"

	@AppStorage("petar.uiLab.badgeTextColor")
	private var badgeTextColorHex: String = "#FFFFFF"

	let count: Int

	var body: some View {
		Text(count.description)
			.font(.system(size: badgeFontSize, weight: .bold))
			.foregroundStyle(Color(hex: badgeTextColorHex))
			.frame(width: badgeSize, height: badgeSize)
			.background(
				Circle()
					.fill(Color(hex: badgeColorHex))
			)
	}
}


struct FeatherLabSectionHeader: View {
	@AppStorage("petar.uiLab.headerGap")
	private var headerGap: Double = 8

	@AppStorage("petar.uiLab.headerAlignment")
	private var headerAlignment: Int = 0

	let title: String
	let count: Int

	var body: some View {
		HStack(spacing: headerGap) {
			if headerAlignment == 1 || headerAlignment == 2 {
				Spacer(minLength: 0)
			}

			Text(title)

			FeatherLabCountBadge(count: count)

			if headerAlignment == 0 || headerAlignment == 1 {
				Spacer(minLength: 0)
			}
		}
	}
}

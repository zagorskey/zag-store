import SwiftUI

// MARK: - Standard Zag Store Badge

struct ZagCountBadge: View {
	@AppStorage("zagStore.designer.standardBadge.size")
	private var badgeSize: Double = 22

	@AppStorage("zagStore.designer.standardBadge.fontSize")
	private var badgeFontSize: Double = 14

	@AppStorage("zagStore.designer.standardBadge.background")
	private var badgeColorHex: String = "#8E8E93"

	@AppStorage("zagStore.designer.standardBadge.foreground")
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


// MARK: - Update Badge

struct ZagUpdateBadge: View {
	@AppStorage("zagStore.designer.updateBadge.size")
	private var badgeSize: Double = 22

	@AppStorage("zagStore.designer.updateBadge.fontSize")
	private var badgeFontSize: Double = 14

	@AppStorage("zagStore.designer.updateBadge.background")
	private var badgeColorHex: String = "#FF3B30"

	@AppStorage("zagStore.designer.updateBadge.foreground")
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


// MARK: - Standard Section Header

struct ZagSectionHeader: View {
	@AppStorage("zagStore.designer.header.gap")
	private var headerGap: Double = 8

	@AppStorage("zagStore.designer.header.alignment")
	private var headerAlignment: Int = 0

	let title: String
	let count: Int

	var body: some View {
		HStack(spacing: headerGap) {
			if headerAlignment == 1 || headerAlignment == 2 {
				Spacer(minLength: 0)
			}

			Text(title)

			ZagCountBadge(count: count)

			if headerAlignment == 0 || headerAlignment == 1 {
				Spacer(minLength: 0)
			}
		}
	}
}

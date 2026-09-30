import SwiftUI

// MARK: - Standard Zag Store Badge

struct ZagCountBadge: View {
	@AppStorage("zagStore.designer.standardBadge.size")
	private var badgeSize: Double = 22

	@AppStorage("zagStore.designer.standardBadge.fontSize")
	private var badgeFontSize: Double = 14

	@AppStorage("zagStore.designer.standardBadge.foreground")
	private var badgeTextColorHex: String = "#FFFFFF"

	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#4395F8"

	let count: Int

	var body: some View {
		Text(count.description)
			.font(.system(size: badgeFontSize, weight: .regular))
			.foregroundStyle(Color(hex: badgeTextColorHex))
			.frame(width: badgeSize, height: badgeSize, alignment: .center)
			.background(
				Circle()
					.fill(Color(hex: themeColorHex))
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
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(Color.white)
				.textCase(nil)

			ZagCountBadge(count: count)

			if headerAlignment == 0 || headerAlignment == 1 {
				Spacer(minLength: 0)
			}
		}
	}
}


// MARK: - Standard Zag Store Action Pill

struct ZagActionPill: View {
	let title: String
	var showsProgress: Bool = false
	let action: () -> Void

	@Environment(\.colorScheme)
	private var colorScheme

	private var pillBackground: Color {
		colorScheme == .dark
			? Color(hex: "#1C1C1E")
			: Color(hex: "#F2F2F7")
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if showsProgress {
					ProgressView()
						.controlSize(.small)
				}

				Text(title)
					.font(.headline)
					.lineLimit(1)
			}
			.frame(width: 88, height: 34)
			.foregroundStyle(Color.accentColor)
			.background(pillBackground)
			.clipShape(Capsule())
			.contentShape(Capsule())
		}
		.buttonStyle(.borderless)
	}
}

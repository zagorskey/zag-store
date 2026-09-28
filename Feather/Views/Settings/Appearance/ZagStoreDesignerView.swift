import SwiftUI
import NimbleViews

struct ZagStoreDesignerView: View {
	// MARK: - Standard Badge

	@AppStorage("zagStore.designer.standardBadge.size")
	private var standardBadgeSize: Double = 22

	@AppStorage("zagStore.designer.standardBadge.fontSize")
	private var standardBadgeFontSize: Double = 14

	@AppStorage("zagStore.designer.standardBadge.background")
	private var standardBadgeColor: String = "#8E8E93"

	@AppStorage("zagStore.designer.standardBadge.foreground")
	private var standardBadgeTextColor: String = "#FFFFFF"

	// MARK: - Update Badge

	@AppStorage("zagStore.designer.updateBadge.size")
	private var updateBadgeSize: Double = 22

	@AppStorage("zagStore.designer.updateBadge.fontSize")
	private var updateBadgeFontSize: Double = 14

	@AppStorage("zagStore.designer.updateBadge.background")
	private var updateBadgeColor: String = "#FF3B30"

	@AppStorage("zagStore.designer.updateBadge.foreground")
	private var updateBadgeTextColor: String = "#FFFFFF"

	// MARK: - Headers

	@AppStorage("zagStore.designer.header.gap")
	private var headerGap: Double = 8

	@AppStorage("zagStore.designer.header.alignment")
	private var headerAlignment: Int = 0

	// MARK: - Rows

	@AppStorage("zagStore.designer.row.spacing")
	private var rowSpacing: Double = 18

	@AppStorage("zagStore.designer.row.iconSize")
	private var rowIconSize: Double = 57

	@AppStorage("zagStore.designer.row.horizontalPadding")
	private var rowHorizontalPadding: Double = 0

	@AppStorage("zagStore.designer.row.verticalPadding")
	private var rowVerticalPadding: Double = 0

	// MARK: - Separators

	@AppStorage("zagStore.designer.separator.enabled")
	private var separatorsEnabled: Bool = true

	@AppStorage("zagStore.designer.separator.opacity")
	private var separatorOpacity: Double = 1

	@AppStorage("zagStore.designer.separator.leadingInset")
	private var separatorLeadingInset: Double = 0

	@AppStorage("zagStore.designer.separator.trailingInset")
	private var separatorTrailingInset: Double = 0

	// MARK: - Updates

	@AppStorage("zagStore.designer.update.dotSize")
	private var updateDotSize: Double = 9

	@AppStorage("zagStore.designer.update.dotColor")
	private var updateDotColor: String = "#34C759"

	@AppStorage("zagStore.designer.update.pulseEnabled")
	private var updatePulseEnabled: Bool = true

	@AppStorage("zagStore.designer.update.pulseSpeed")
	private var updatePulseSpeed: Double = 0.8

	var body: some View {
		NBList("Zag Store Designer") {
			previewSection
			standardBadgeSection
			updateBadgeSection
			headerSection
			rowSection
			separatorSection
			updateIndicatorSection
			resetSection
		}
	}

	// MARK: - Preview

	private var previewSection: some View {
		Section("Live Preview") {
			VStack(alignment: .leading, spacing: 16) {
				Text("Library Headers")
					.font(.caption)
					.foregroundStyle(.secondary)

				ZagSectionHeader(
					title: "Signed",
					count: 3
				)

				ZagSectionHeader(
					title: "Repositories",
					count: 5
				)

				Divider()

				Text("Updates Header")
					.font(.caption)
					.foregroundStyle(.secondary)

				HStack(spacing: headerGap) {
					if headerAlignment == 1 || headerAlignment == 2 {
						Spacer(minLength: 0)
					}

					Circle()
						.fill(Color(hex: updateDotColor))
						.frame(
							width: updateDotSize,
							height: updateDotSize
						)

					Text("Updates Available")

					ZagUpdateBadge(count: 2)

					if headerAlignment == 0 || headerAlignment == 1 {
						Spacer(minLength: 0)
					}
				}

				Divider()

				HStack(spacing: rowSpacing) {
					RoundedRectangle(
						cornerRadius: 12,
						style: .continuous
					)
					.fill(Color.accentColor.opacity(0.2))
					.frame(
						width: rowIconSize,
						height: rowIconSize
					)
					.overlay {
						Image(systemName: "app.fill")
							.foregroundStyle(Color.accentColor)
					}

					VStack(alignment: .leading) {
						Text("Example App")
							.font(.headline)

						Text("2.0.0 → 2.0.1")
							.font(.caption)
							.foregroundStyle(.secondary)
					}

					Spacer()

					Text("Update")
						.foregroundStyle(Color.accentColor)
				}
				.padding(.horizontal, rowHorizontalPadding)
				.padding(.vertical, rowVerticalPadding)
			}
		}
	}

	// MARK: - Standard Badges

	private var standardBadgeSection: some View {
		Section("Standard Badges") {
			HStack {
				Text("Preview")
				.foregroundStyle(.secondary)

				Spacer()

				ZagCountBadge(count: 8)
			}

			designerSlider(
				"Diameter",
				value: $standardBadgeSize,
				range: 16...36,
				step: 1
			)

			designerSlider(
				"Font Size",
				value: $standardBadgeFontSize,
				range: 8...24,
				step: 1
			)

			ColorPicker(
				"Background",
				selection: colorBinding($standardBadgeColor),
				supportsOpacity: false
			)

			ColorPicker(
				"Text",
				selection: colorBinding($standardBadgeTextColor),
				supportsOpacity: false
			)
		}
	}

	// MARK: - Update Badge

	private var updateBadgeSection: some View {
		Section("Update Badge") {
			HStack {
				Text("Preview")
					.foregroundStyle(.secondary)

				Spacer()

				ZagUpdateBadge(count: 2)
			}

			designerSlider(
				"Diameter",
				value: $updateBadgeSize,
				range: 16...36,
				step: 1
			)

			designerSlider(
				"Font Size",
				value: $updateBadgeFontSize,
				range: 8...24,
				step: 1
			)

			ColorPicker(
				"Background",
				selection: colorBinding($updateBadgeColor),
				supportsOpacity: false
			)

			ColorPicker(
				"Text",
				selection: colorBinding($updateBadgeTextColor),
				supportsOpacity: false
			)
		}
	}

	// MARK: - Headers

	private var headerSection: some View {
		Section("Headers") {
			Picker("Alignment", selection: $headerAlignment) {
				Text("Left").tag(0)
				Text("Centre").tag(1)
				Text("Right").tag(2)
			}
			.pickerStyle(.segmented)

			designerSlider(
				"Badge Gap",
				value: $headerGap,
				range: 0...30,
				step: 1
			)
		}
	}

	// MARK: - Rows

	private var rowSection: some View {
		Section("Rows") {
			designerSlider(
				"Content Spacing",
				value: $rowSpacing,
				range: 0...40,
				step: 1
			)

			designerSlider(
				"Icon Size",
				value: $rowIconSize,
				range: 30...90,
				step: 1
			)

			designerSlider(
				"Horizontal Padding",
				value: $rowHorizontalPadding,
				range: 0...30,
				step: 1
			)

			designerSlider(
				"Vertical Padding",
				value: $rowVerticalPadding,
				range: 0...30,
				step: 1
			)
		}
	}

	// MARK: - Separators

	private var separatorSection: some View {
		Section("Separators") {
			Toggle(
				"Show Separators",
				isOn: $separatorsEnabled
			)

			designerSlider(
				"Opacity",
				value: $separatorOpacity,
				range: 0...1,
				step: 0.05
			)
			.disabled(!separatorsEnabled)

			designerSlider(
				"Leading Inset",
				value: $separatorLeadingInset,
				range: 0...120,
				step: 1
			)
			.disabled(!separatorsEnabled)

			designerSlider(
				"Trailing Inset",
				value: $separatorTrailingInset,
				range: 0...120,
				step: 1
			)
			.disabled(!separatorsEnabled)
		}
	}

	// MARK: - Update Indicator

	private var updateIndicatorSection: some View {
		Section("Update Indicator") {
			Toggle(
				"Pulse",
				isOn: $updatePulseEnabled
			)

			designerSlider(
				"Status Dot Size",
				value: $updateDotSize,
				range: 4...20,
				step: 1
			)

			ColorPicker(
				"Status Dot Colour",
				selection: colorBinding($updateDotColor),
				supportsOpacity: false
			)

			designerSlider(
				"Pulse Speed",
				value: $updatePulseSpeed,
				range: 0.2...2,
				step: 0.1
			)
			.disabled(!updatePulseEnabled)
		}
	}

	// MARK: - Reset

	private var resetSection: some View {
		Section {
			Button(
				"Reset Zag Store Designer",
				role: .destructive
			) {
				resetDefaults()
			}
		}
	}

	// MARK: - Helpers

	private func designerSlider(
		_ title: String,
		value: Binding<Double>,
		range: ClosedRange<Double>,
		step: Double
	) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			HStack {
				Text(title)

				Spacer()

				Text(
					value.wrappedValue.rounded() == value.wrappedValue
						? "\(Int(value.wrappedValue))"
						: String(format: "%.1f", value.wrappedValue)
				)
				.foregroundStyle(.secondary)
				.monospacedDigit()
			}

			Slider(
				value: value,
				in: range,
				step: step
			)
		}
	}

	private func colorBinding(
		_ value: Binding<String>
	) -> Binding<Color> {
		Binding(
			get: {
				Color(hex: value.wrappedValue)
			},
			set: {
				value.wrappedValue = $0.toHex()
			}
		)
	}

	private func resetDefaults() {
		standardBadgeSize = 22
		standardBadgeFontSize = 14
		standardBadgeColor = "#8E8E93"
		standardBadgeTextColor = "#FFFFFF"

		updateBadgeSize = 22
		updateBadgeFontSize = 14
		updateBadgeColor = "#FF3B30"
		updateBadgeTextColor = "#FFFFFF"

		headerGap = 8
		headerAlignment = 0

		rowSpacing = 18
		rowIconSize = 57
		rowHorizontalPadding = 0
		rowVerticalPadding = 0

		separatorsEnabled = true
		separatorOpacity = 1
		separatorLeadingInset = 0
		separatorTrailingInset = 0

		updateDotSize = 9
		updateDotColor = "#34C759"
		updatePulseEnabled = true
		updatePulseSpeed = 0.8
	}
}

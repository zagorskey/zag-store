import SwiftUI
import NimbleViews

struct UILabView: View {
	// MARK: - Badges

	@AppStorage("petar.uiLab.badgeSize")
	private var badgeSize: Double = 22

	@AppStorage("petar.uiLab.badgeFontSize")
	private var badgeFontSize: Double = 14

	@AppStorage("petar.uiLab.badgeColor")
	private var badgeColorHex: String = "#FF3B30"

	@AppStorage("petar.uiLab.badgeTextColor")
	private var badgeTextColorHex: String = "#FFFFFF"

	// MARK: - Headers

	@AppStorage("petar.uiLab.headerGap")
	private var headerGap: Double = 8

	@AppStorage("petar.uiLab.headerAlignment")
	private var headerAlignment: Int = 0

	// MARK: - Rows

	@AppStorage("petar.uiLab.rowSpacing")
	private var rowSpacing: Double = 18

	@AppStorage("petar.uiLab.rowIconSize")
	private var rowIconSize: Double = 57

	@AppStorage("petar.uiLab.rowHorizontalPadding")
	private var rowHorizontalPadding: Double = 0

	@AppStorage("petar.uiLab.rowVerticalPadding")
	private var rowVerticalPadding: Double = 0

	// MARK: - Separators

	@AppStorage("petar.uiLab.separatorsEnabled")
	private var separatorsEnabled: Bool = true

	@AppStorage("petar.uiLab.separatorOpacity")
	private var separatorOpacity: Double = 1

	@AppStorage("petar.uiLab.separatorLeadingInset")
	private var separatorLeadingInset: Double = 0

	@AppStorage("petar.uiLab.separatorTrailingInset")
	private var separatorTrailingInset: Double = 0

	// MARK: - Updates

	@AppStorage("petar.uiLab.updateDotSize")
	private var updateDotSize: Double = 9

	@AppStorage("petar.uiLab.updatePulseSpeed")
	private var updatePulseSpeed: Double = 0.8

	var body: some View {
		NBList("UI Lab") {
			previewSection
			badgeSection
			headerSection
			rowSection
			separatorSection
			updateSection
			resetSection
		}
	}

	// MARK: - Preview

	private var previewSection: some View {
		Section("Live Preview") {
			HStack(spacing: headerGap) {
				if headerAlignment > 0 {
					Spacer(minLength: 0)
				}

				Circle()
					.fill(Color.green)
					.frame(
						width: updateDotSize,
						height: updateDotSize
					)

				Text("Updates Available")

				Text("1")
					.font(.system(
						size: badgeFontSize,
						weight: .bold
					))
					.foregroundStyle(Color(hex: badgeTextColorHex))
					.frame(
						width: badgeSize,
						height: badgeSize
					)
					.background(
						Circle()
							.fill(Color(hex: badgeColorHex))
					)

				if headerAlignment < 2 {
					Spacer(minLength: 0)
				}
			}

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

	// MARK: - Controls

	private var badgeSection: some View {
		Section("Badges") {
			labSlider(
				"Diameter",
				value: $badgeSize,
				range: 16...36,
				step: 1
			)

			labSlider(
				"Font Size",
				value: $badgeFontSize,
				range: 8...24,
				step: 1
			)

			ColorPicker(
				"Badge Colour",
				selection: colorBinding($badgeColorHex),
				supportsOpacity: false
			)

			ColorPicker(
				"Text Colour",
				selection: colorBinding($badgeTextColorHex),
				supportsOpacity: false
			)
		}
	}

	private var headerSection: some View {
		Section("Headers") {
			Picker("Alignment", selection: $headerAlignment) {
				Text("Left").tag(0)
				Text("Centre").tag(1)
				Text("Right").tag(2)
			}
			.pickerStyle(.segmented)

			labSlider(
				"Badge Gap",
				value: $headerGap,
				range: 0...30,
				step: 1
			)
		}
	}

	private var rowSection: some View {
		Section("Rows") {
			labSlider(
				"Content Spacing",
				value: $rowSpacing,
				range: 0...40,
				step: 1
			)

			labSlider(
				"Icon Size",
				value: $rowIconSize,
				range: 30...90,
				step: 1
			)

			labSlider(
				"Horizontal Padding",
				value: $rowHorizontalPadding,
				range: 0...30,
				step: 1
			)

			labSlider(
				"Vertical Padding",
				value: $rowVerticalPadding,
				range: 0...30,
				step: 1
			)
		}
	}

	private var separatorSection: some View {
		Section("Separators") {
			Toggle(
				"Show Separators",
				isOn: $separatorsEnabled
			)

			labSlider(
				"Opacity",
				value: $separatorOpacity,
				range: 0...1,
				step: 0.05
			)
			.disabled(!separatorsEnabled)

			labSlider(
				"Leading Inset",
				value: $separatorLeadingInset,
				range: 0...120,
				step: 1
			)
			.disabled(!separatorsEnabled)

			labSlider(
				"Trailing Inset",
				value: $separatorTrailingInset,
				range: 0...120,
				step: 1
			)
			.disabled(!separatorsEnabled)
		}
	}

	private var updateSection: some View {
		Section("Updates") {
			labSlider(
				"Status Dot Size",
				value: $updateDotSize,
				range: 4...20,
				step: 1
			)

			labSlider(
				"Pulse Speed",
				value: $updatePulseSpeed,
				range: 0.2...2,
				step: 0.1
			)
		}
	}

	private var resetSection: some View {
		Section {
			Button(
				"Reset UI Lab",
				role: .destructive
			) {
				resetDefaults()
			}
		}
	}

	// MARK: - Helpers

	private func labSlider(
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
		badgeSize = 22
		badgeFontSize = 14
		badgeColorHex = "#FF3B30"
		badgeTextColorHex = "#FFFFFF"

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
		updatePulseSpeed = 0.8
	}
}

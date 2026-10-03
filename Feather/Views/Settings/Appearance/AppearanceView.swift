//
//  AppearanceView.swift
//  Zag Store
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View

struct AppearanceView: View {
	@AppStorage(ZagWallpaperStore.enabledKey)
	private var _wallpaperEnabled = false

	@AppStorage(ZagWallpaperStore.blurKey)
	private var _wallpaperBlurred = false

	@AppStorage(ZagWallpaperStore.blurAmountKey)
	private var _wallpaperBlurAmount: Double = 16

	@AppStorage(ZagWallpaperStore.brightnessKey)
	private var _wallpaperBrightnessEnabled = false

	@AppStorage(ZagWallpaperStore.brightnessAmountKey)
	private var _wallpaperBrightnessAmount: Double = 1

	@State private var _wallpaperPickerPresenting = false
	@AppStorage("Feather.userInterfaceStyle")
	private var _userIntefacerStyle: Int =
		UIUserInterfaceStyle.unspecified.rawValue

	@AppStorage("Feather.shouldTintIcons")
	private var _shouldTintIcons: Bool = false

	@AppStorage("Feather.shouldChangeIconsBasedOffStyle")
	private var _shouldChangeIconsBasedOffStyle: Bool = false

	@AppStorage("Feather.storeCellAppearance")
	private var _storeCellAppearance: Int = 0

	private let _storeCellAppearanceMethods:
		[(name: String, desc: String)] = [
			(
				.localized("Standard"),
				.localized(
					"Default style for the app, only includes subtitle."
				)
			),
			(
				.localized("Big Description"),
				.localized(
					"Adds the localized description of the app."
				)
			)
		]

	@AppStorage("Feather.userTintColor")
	private var _selectedColorHex: String = "#4395F8"

	private var _tintColorBinding: Binding<Color> {
		Binding(
			get: {
				Color(hex: _selectedColorHex)
			},
			set: {
				_selectedColorHex = $0.toHex()
			}
		)
	}

	private let _appearanceChoices:
		[(label: String, value: Int)] = [
			(
				"Auto",
				UIUserInterfaceStyle.unspecified.rawValue
			),
			(
				"Light",
				UIUserInterfaceStyle.light.rawValue
			),
			(
				"Dark",
				UIUserInterfaceStyle.dark.rawValue
			)
		]

	// MARK: Body

	var body: some View {
		NBList(.localized("Appearance"), transparentBackground: true) {
			Section {
				Picker(
					.localized("Appearance"),
					selection: $_userIntefacerStyle
				) {
					ForEach(
						_appearanceChoices,
						id: \.value
					) { choice in
						Text(.localized(choice.label))
							.tag(choice.value)
					}
				}
				.pickerStyle(.segmented)
			}

			NBSection(.localized("Theme")) {
				AppearanceTintColorView()
					.listRowInsets(EdgeInsets())
					.listRowBackground(EmptyView())
			}

			Section {
				ColorPicker(
					.localized("Custom Theme Color"),
					selection: _tintColorBinding,
					supportsOpacity: false
				)
			}

			Section(.localized("Wallpaper")) {
				Button {
					_wallpaperPickerPresenting = true
				} label: {
					Label(
						 .localized(_wallpaperEnabled ? "Change" : "Browse"),
						systemImage: "photo"
					)
				}
				.foregroundStyle(.white)

				if _wallpaperEnabled {
					Toggle(isOn: $_wallpaperBlurred) {
						Label("Blur", systemImage: "drop.fill")
							.foregroundStyle(Color(hex: _selectedColorHex))
					}

					if _wallpaperBlurred {
						VStack(alignment: .leading, spacing: 8) {
							HStack {
								Image(systemName: "minus")
									.foregroundStyle(.secondary)

								Slider(
									value: $_wallpaperBlurAmount,
									in: 0...30,
									step: 1
								)

								Image(systemName: "plus")
									.foregroundStyle(.secondary)
							}
							.accessibilityElement(children: .combine)
							.accessibilityLabel("Wallpaper Blur")
							.accessibilityValue("\(Int(_wallpaperBlurAmount))")
						}
					}

					Toggle(isOn: $_wallpaperBrightnessEnabled) {
						Label("Brightness", systemImage: "sun.max.fill")
							.foregroundStyle(Color(hex: _selectedColorHex))
					}

					if _wallpaperBrightnessEnabled {
						HStack {
							Image(systemName: "sun.min")
								.foregroundStyle(.secondary)

							Slider(
								value: $_wallpaperBrightnessAmount,
								in: 0.05...1,
								step: 0.01
							)

							Image(systemName: "sun.max.fill")
								.foregroundStyle(.secondary)
						}
						.accessibilityElement(children: .combine)
						.accessibilityLabel("Wallpaper Brightness")
						.accessibilityValue("\(Int(_wallpaperBrightnessAmount * 100)) percent")
					}

					Button(role: .destructive) {
						ZagWallpaperStore.clear()
						_wallpaperEnabled = false
					} label: {
						Label(.localized("Clear"), systemImage: "trash")
					}
				}
			}

			if #available(iOS 18.0, *) {
				NBSection(.localized("Library")) {
					Toggle(
						.localized("Dynamic Icons"),
						isOn:
							$_shouldChangeIconsBasedOffStyle
					)

					if #available(iOS 18.2, *) {
						Toggle(
							.localized("Tinted Icons"),
							isOn: $_shouldTintIcons
						)
					}
				}
			}

			NBSection(.localized("Sources")) {
				Picker(
					.localized("Store Cell Appearance"),
					selection: $_storeCellAppearance
				) {
					ForEach(
						0..<_storeCellAppearanceMethods.count,
						id: \.self
					) { index in
						let method =
							_storeCellAppearanceMethods[index]

						NBTitleWithSubtitleView(
							title: method.name,
							subtitle: method.desc
						)
						.tag(index)
					}
				}
				.labelsHidden()
				.pickerStyle(.inline)
			}
		}
		.background {
			ZagWallpaperBackground()
		}
		.sheet(isPresented: $_wallpaperPickerPresenting) {
			ZagWallpaperPicker { image in
				try? ZagWallpaperStore.save(image)
				_wallpaperEnabled = true
			}
		}
		.onChange(of: _userIntefacerStyle) { value in
			if let style =
				UIUserInterfaceStyle(rawValue: value) {
				UIApplication
					.topViewController()?
					.view
					.window?
					.overrideUserInterfaceStyle =
						style
			}
		}
	}
}

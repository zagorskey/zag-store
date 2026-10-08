//
//  AppearanceTintColorView.swift
//  Feather
//
//  Created by samara on 14.06.2025.
//

import SwiftUI

// MARK: - View
struct AppearanceTintColorView: View {
	@AppStorage("Feather.userTintColor") private var _selectedColorHex: String = "#3F8EF7"
	private let _tintOptions: [(name: String, hex: String)] = [
		("Native", 		"#3F8EF7"),
		("Violet", 			"#B496DC"),
		("Matrix",   		"#008F11"),
		("Cool Blue", 		"#4161F1"),
		("Fuchsia", 		"#FF00FF"),
		("Protokolle", 		"#4CD964"),
		("Aidoku", 			"#FF2D55"),
		("Clock", 			"#FF9500"),
		("Peculiar", 		"#4860e8"),
		("Very Peculiar", 	"#5394F7"),
		("Emily",			"#e18aab")
	]
	// MARK: Body
	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			LazyHGrid(rows: [GridItem(.fixed(100))], spacing: 12) {
				ForEach(_tintOptions, id: \.hex) { option in
					let color = ZagWideGamutTint.color(hex: option.hex)
					let cornerRadius = {
						if #available(iOS 26.0, *) {
							28.0
						} else {
							10.5
						}
					}()
					VStack(spacing: 8) {
						Circle()
							.fill(color)
							.frame(width: 30, height: 30)
							.overlay(
								Circle()
									.strokeBorder(Color.black.opacity(0.3), lineWidth: 2)
							)

						Text(option.name)
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					.frame(width: 120, height: 100)
					.background(Color(uiColor: .secondarySystemGroupedBackground))
					.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
					.overlay(
						RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
							.strokeBorder(_selectedColorHex == option.hex ? color : .clear, lineWidth: 2)
					)
					.onTapGesture {
						_selectedColorHex = option.hex
					}
					.accessibilityLabel(Text(option.name))
				}
			}
		}
		.onAppear {
			// Migrate the former Berry selection to Matrix once.
			if _selectedColorHex.lowercased() == "#ff7a83" {
				_selectedColorHex = "#008F11"
			}
		}
		.onChange(of: _selectedColorHex) { value in
			UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: value))
		}
	}
}

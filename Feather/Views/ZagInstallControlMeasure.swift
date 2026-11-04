import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Measures labels with the same fonts the control renders, so the pill width
/// is known before the morph starts.
enum ZagInstallControlMeasure {
	static func pillWidth(_ pill: ZagInstallPill) -> Double {
		ZagInstallControlLayout.pillWidth(contentWidth: contentWidth(pill))
	}

	static func contentWidth(_ pill: ZagInstallPill) -> Double {
		let font = pill.labelFont
		let symbol = pill.systemImage.map { name in
			pill.title == nil
				? symbolWidth(name, pointSize: pill.iconSize, weight: nil)
				: symbolWidth(name, pointSize: font.size, weight: font)
		}
		let title = pill.title.map { titleWidth($0, font: font) }
		return ZagInstallControlLayout.contentWidth(titleWidth: title, symbolWidth: symbol, spacing: font.iconSpacing)
	}

	#if canImport(UIKit)
	typealias Weight = UIFont.Weight
	#else
	typealias Weight = NSFont.Weight
	#endif

	static func weight(_ font: ZagInstallLabelFont) -> Weight {
		font.semibold ? .semibold : .bold
	}

	static func titleWidth(_ title: String, font: ZagInstallLabelFont = .standard) -> Double {
		#if canImport(UIKit)
		let f = UIFont.systemFont(ofSize: font.size, weight: weight(font))
		#else
		let f = NSFont.systemFont(ofSize: font.size, weight: weight(font))
		#endif
		return Double((title as NSString).size(withAttributes: [.font: f]).width).rounded(.up)
	}

	#if canImport(UIKit)
	/// Symbol weight matching a label font; nil is regular (icon-only pills).
	static func symbolWeight(_ font: ZagInstallLabelFont?) -> UIImage.SymbolWeight {
		guard let font else { return .regular }
		return font.semibold ? .semibold : .bold
	}
	#else
	static func symbolWeight(_ font: ZagInstallLabelFont?) -> NSFont.Weight {
		guard let font else { return .regular }
		return weight(font)
	}
	#endif

	static func symbolWidth(_ name: String, pointSize: Double, weight font: ZagInstallLabelFont?) -> Double {
		let weight = symbolWeight(font)
		#if canImport(UIKit)
		let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
		return (UIImage(systemName: name, withConfiguration: config).map { Double($0.size.width) } ?? pointSize).rounded(.up)
		#else
		let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
		return (image.map { Double($0.size.width) } ?? pointSize).rounded(.up)
		#endif
	}
}

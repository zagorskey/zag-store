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
		let size = pill.title == nil ? pill.iconSize : ZagInstallControlLayout.titleSize
		let symbol = pill.systemImage.map { symbolWidth($0, pointSize: size, bold: pill.title != nil) }
		let title = pill.title.map(titleWidth)
		return ZagInstallControlLayout.contentWidth(titleWidth: title, symbolWidth: symbol)
	}

	static func titleWidth(_ title: String) -> Double {
		#if canImport(UIKit)
		let font = UIFont.systemFont(ofSize: ZagInstallControlLayout.titleSize, weight: .bold)
		#else
		let font = NSFont.systemFont(ofSize: ZagInstallControlLayout.titleSize, weight: .bold)
		#endif
		return Double((title as NSString).size(withAttributes: [.font: font]).width).rounded(.up)
	}

	static func symbolWidth(_ name: String, pointSize: Double, bold: Bool) -> Double {
		#if canImport(UIKit)
		let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: bold ? .bold : .regular)
		return (UIImage(systemName: name, withConfiguration: config).map { Double($0.size.width) } ?? pointSize).rounded(.up)
		#else
		let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: bold ? .bold : .regular)
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
		return (image.map { Double($0.size.width) } ?? pointSize).rounded(.up)
		#endif
	}
}

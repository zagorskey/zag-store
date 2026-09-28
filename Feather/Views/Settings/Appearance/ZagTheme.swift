import SwiftUI

enum ZagTheme {
	// MARK: - Standard Badge

	static var standardBadgeSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.standardBadge.size") as? Double ?? 22
	}

	static var standardBadgeFontSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.standardBadge.fontSize") as? Double ?? 14
	}

	static var standardBadgeColorHex: String {
		UserDefaults.standard.string(forKey: "zagStore.designer.standardBadge.background") ?? "#8E8E93"
	}

	static var standardBadgeTextColorHex: String {
		UserDefaults.standard.string(forKey: "zagStore.designer.standardBadge.foreground") ?? "#FFFFFF"
	}

	// MARK: - Update Badge

	static var updateBadgeSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.updateBadge.size") as? Double ?? 22
	}

	static var updateBadgeFontSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.updateBadge.fontSize") as? Double ?? 14
	}

	static var updateBadgeColorHex: String {
		UserDefaults.standard.string(forKey: "zagStore.designer.updateBadge.background") ?? "#FF3B30"
	}

	static var updateBadgeTextColorHex: String {
		UserDefaults.standard.string(forKey: "zagStore.designer.updateBadge.foreground") ?? "#FFFFFF"
	}

	// MARK: - Header

	static var headerFontSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.header.fontSize") as? Double ?? 13
	}

	static var headerColorHex: String {
		UserDefaults.standard.string(forKey: "zagStore.designer.header.color") ?? "#8E8E93"
	}

	static var headerGap: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.header.gap") as? Double ?? 8
	}

	static var headerAlignment: Int {
		UserDefaults.standard.object(forKey: "zagStore.designer.header.alignment") as? Int ?? 0
	}

	static var headerVerticalPadding: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.header.verticalPadding") as? Double ?? 0
	}

	// MARK: - Rows

	static var rowSpacing: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.row.spacing") as? Double ?? 18
	}

	static var rowIconSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.row.iconSize") as? Double ?? 57
	}

	static var rowIconRadius: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.row.iconRadius") as? Double ?? 12
	}

	static var rowHorizontalPadding: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.row.horizontalPadding") as? Double ?? 0
	}

	static var rowVerticalPadding: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.row.verticalPadding") as? Double ?? 0
	}

	static var rowMinHeight: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.row.minHeight") as? Double ?? 0
	}

	// MARK: - Separators

	static var separatorsEnabled: Bool {
		if UserDefaults.standard.object(forKey: "zagStore.designer.separator.enabled") == nil {
			return true
		}
		return UserDefaults.standard.bool(forKey: "zagStore.designer.separator.enabled")
	}

	static var separatorOpacity: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.separator.opacity") as? Double ?? 1
	}

	static var separatorColorHex: String {
		UserDefaults.standard.string(forKey: "zagStore.designer.separator.color") ?? "#3C3C43"
	}

	static var separatorLeadingInset: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.separator.leadingInset") as? Double ?? 0
	}

	static var separatorTrailingInset: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.separator.trailingInset") as? Double ?? 0
	}

	// MARK: - Updates

	static var updateDotSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.update.dotSize") as? Double ?? 9
	}

	static var updateDotColorHex: String {
		UserDefaults.standard.string(forKey: "zagStore.designer.update.dotColor") ?? "#34C759"
	}

	static var updatePulseEnabled: Bool {
		if UserDefaults.standard.object(forKey: "zagStore.designer.update.pulseEnabled") == nil {
			return true
		}
		return UserDefaults.standard.bool(forKey: "zagStore.designer.update.pulseEnabled")
	}

	static var updatePulseSpeed: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.update.pulseSpeed") as? Double ?? 0.8
	}

	static var updateIconSize: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.update.iconSize") as? Double ?? 48
	}

	static var updateIconRadius: Double {
		UserDefaults.standard.object(forKey: "zagStore.designer.update.iconRadius") as? Double ?? 11
	}
}

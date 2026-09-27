import SwiftUI

enum FeatherUIStyle {
	// MARK: Badge

	static var badgeSize: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.badgeSize") as? Double ?? 22
	}

	static var badgeFontSize: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.badgeFontSize") as? Double ?? 14
	}

	static var badgeFontWeight: Int {
		UserDefaults.standard.object(forKey: "petar.uiLab.badgeFontWeight") as? Int ?? 6
	}

	static var badgeColorHex: String {
		UserDefaults.standard.string(forKey: "petar.uiLab.badgeColor") ?? "#FF3B30"
	}

	static var badgeTextColorHex: String {
		UserDefaults.standard.string(forKey: "petar.uiLab.badgeTextColor") ?? "#FFFFFF"
	}

	// MARK: Header

	static var headerFontSize: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.headerFontSize") as? Double ?? 13
	}

	static var headerFontWeight: Int {
		UserDefaults.standard.object(forKey: "petar.uiLab.headerFontWeight") as? Int ?? 4
	}

	static var headerColorHex: String {
		UserDefaults.standard.string(forKey: "petar.uiLab.headerColor") ?? "#8E8E93"
	}

	static var headerGap: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.headerGap") as? Double ?? 8
	}

	static var headerAlignment: Int {
		UserDefaults.standard.object(forKey: "petar.uiLab.headerAlignment") as? Int ?? 0
	}

	static var headerVerticalPadding: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.headerVerticalPadding") as? Double ?? 0
	}

	// MARK: Library rows

	static var rowSpacing: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.rowSpacing") as? Double ?? 18
	}

	static var rowIconSize: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.rowIconSize") as? Double ?? 57
	}

	static var rowIconRadius: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.rowIconRadius") as? Double ?? 12
	}

	static var rowHorizontalPadding: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.rowHorizontalPadding") as? Double ?? 0
	}

	static var rowVerticalPadding: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.rowVerticalPadding") as? Double ?? 0
	}

	static var rowMinHeight: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.rowMinHeight") as? Double ?? 0
	}

	// MARK: Separators

	static var separatorsEnabled: Bool {
		if UserDefaults.standard.object(forKey: "petar.uiLab.separatorsEnabled") == nil {
			return true
		}
		return UserDefaults.standard.bool(forKey: "petar.uiLab.separatorsEnabled")
	}

	static var separatorOpacity: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.separatorOpacity") as? Double ?? 1
	}

	static var separatorColorHex: String {
		UserDefaults.standard.string(forKey: "petar.uiLab.separatorColor") ?? "#3C3C43"
	}

	static var separatorLeadingInset: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.separatorLeadingInset") as? Double ?? 0
	}

	static var separatorTrailingInset: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.separatorTrailingInset") as? Double ?? 0
	}

	// MARK: Updates

	static var updateDotSize: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.updateDotSize") as? Double ?? 9
	}

	static var updateDotColorHex: String {
		UserDefaults.standard.string(forKey: "petar.uiLab.updateDotColor") ?? "#34C759"
	}

	static var updatePulseEnabled: Bool {
		if UserDefaults.standard.object(forKey: "petar.uiLab.updatePulseEnabled") == nil {
			return true
		}
		return UserDefaults.standard.bool(forKey: "petar.uiLab.updatePulseEnabled")
	}

	static var updatePulseSpeed: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.updatePulseSpeed") as? Double ?? 0.8
	}

	static var updateIconSize: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.updateIconSize") as? Double ?? 48
	}

	static var updateIconRadius: Double {
		UserDefaults.standard.object(forKey: "petar.uiLab.updateIconRadius") as? Double ?? 11
	}
}

//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import NimbleViews

enum ZagPageStartupPolicy {
	static let rememberLastPageKey = "zagStore.navigation.rememberLastPage"
	static let defaultStartPageKey = "zagStore.navigation.defaultStartPage"
	static let lastPageKey = "zagStore.navigation.selectedTab"

	static var remembersLastPage: Bool {
		let defaults = UserDefaults.standard
		guard defaults.object(forKey: rememberLastPageKey) != nil else {
			return true
		}
		return defaults.bool(forKey: rememberLastPageKey)
	}

	static var initialTab: TabEnum {
		let defaults = UserDefaults.standard
		let rawValue = remembersLastPage
			? defaults.string(forKey: lastPageKey)
			: defaults.string(forKey: defaultStartPageKey)
		return TabEnum(rawValue: rawValue ?? TabEnum.sources.rawValue) ?? .sources
	}
}

enum TabEnum: String, CaseIterable, Hashable {
	case home
	case sources
	case library
	case settings
	case certificates
	
	var title: String {
		switch self {
		case .home:			return .localized("Home")
		case .sources:     	return .localized("Sources")
		case .library: 		return .localized("Apps")
		case .settings: 	return .localized("Settings")
		case .certificates:	return .localized("Certificates")
		}
	}
	
	var icon: String {
		switch self {
		case .home:			return "house.fill"
		case .sources: 		return "atom"
		case .library: 		return "square.stack.3d.up.fill"
		case .settings: 	return "gearshape.fill"
		case .certificates: return "person.text.rectangle"
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .home: NBNavigationView(.localized("Home")) {
			Color.clear
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.zagWallpaperSurface()
		}
		case .sources: SourcesView()
		case .library: LibraryView()
		case .settings: SettingsView()
		case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.home,
			.sources,
			.library,
			.settings
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return [
			.certificates
		]
	}
}

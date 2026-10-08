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
		let migrated = rawValue == "home" ? TabEnum.discover.rawValue : rawValue
        let tab = TabEnum(rawValue: migrated ?? TabEnum.sources.rawValue) ?? .sources
        return TabEnum.defaultTabs.contains(tab) ? tab : .sources
	}
}

enum TabEnum: String, CaseIterable, Hashable {
	case discover
	case activity
	case devices
	case sources
	case library
	case settings
	case certificates
	
	// Stable internal destinations for the five primary tabs.
    var internalURL: URL? { URL(string: "zagstore://\(rawValue == "library" ? "apps" : rawValue)") }

    static func tab(for url: URL) -> TabEnum? {
        guard url.scheme?.lowercased() == "zagstore" else { return nil }
        let destination = (url.host ?? "").lowercased()
        switch destination {
        case "discover", "home": return .discover
        case "sources": return .sources
        case "apps", "library": return .library
        case "activity": return .activity
        case "devices": return .devices
        default: return nil
        }
    }

	var title: String {
		switch self {
		case .discover:		return "Discover"
		case .activity:		return "Activity"
		case .devices:		return "Devices"
		case .sources:     	return .localized("Sources")
		case .library: 		return .localized("Apps")
		case .settings: 	return .localized("Settings")
		case .certificates:	return .localized("Certificates")
		}
	}
	
	var icon: String {
		switch self {
		case .discover:		return "safari.fill"
		case .activity:		return "clock.arrow.circlepath"
		case .devices:		return "iphone"
		case .sources: 		return "atom"
		case .library: 		return "square.stack.3d.up.fill"
		case .settings: 	return "gearshape.fill"
		case .certificates: return "person.text.rectangle"
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .discover: NBNavigationView("Discover") {
			Color.clear
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.zagWallpaperSurface()
				.toolbar {
					ToolbarItem(placement: .topBarTrailing) {
						ZagProfileToolbarButton()
					}
				}
		}
		case .activity: ZagActivityPage()
		case .devices: ZagDevicesPage()
		case .sources: SourcesView()
		case .library: LibraryView()
		case .settings: SettingsView()
		case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.discover,
			.sources,
			.library,
			.activity,
			.devices
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return [
			.certificates
		]
	}
}


// Initial dedicated destinations; the existing Apps and RPPairing workflows
// remain untouched while Activity and device registration are developed.
private struct ZagActivityPage: View {
    var body: some View {
        NBNavigationView("Activity") {
            ZagEmptyDestination(title: "No Recent Activity", symbol: "clock.arrow.circlepath",
                message: "App installation, signing and refresh activity will appear here.")
                .toolbar {
                    ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                    ToolbarItem(placement: .topBarTrailing) { ZagProfileToolbarButton() }
                }
        }
    }
}

private struct ZagDevicesPage: View {
    var body: some View {
        NBNavigationView("Devices") {
            ZagEmptyDestination(title: "Device Management", symbol: "iphone",
                message: "Registered and paired devices will appear here.")
                .toolbar {
                    ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                    ToolbarItem(placement: .topBarTrailing) { ZagProfileToolbarButton() }
                }
        }
    }
}


// iOS 16-compatible replacement for ContentUnavailableView.
private struct ZagEmptyDestination: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

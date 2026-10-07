import Foundation

extension Notification.Name {
	static let zagStoreRouteRequested = Notification.Name("ZagStore.routeRequested")
}

enum ZagStoreRoute: String, CaseIterable {
	case home
	case sources
	case yourSources
	case apps
	case settings
	case installation
	case installationDiagnostics
	case rppairingDiagnostics
	case updateDiagnostics

	var tab: String {
		switch self {
		case .home: return "home"
		case .sources, .yourSources: return "sources"
		case .apps: return "library"
		default: return "settings"
		}
	}

	var url: URL {
		switch self {
		case .home:
			return URL(string: "zagstore://home")!
		case .sources:
			return URL(string: "zagstore://sources")!
		case .yourSources:
			return URL(string: "zagstore://sources/your-sources")!
		case .apps:
			return URL(string: "zagstore://apps")!
		case .settings:
			return URL(string: "zagstore://settings")!
		case .installation:
			return URL(string: "zagstore://settings/installation")!
		case .installationDiagnostics:
			return URL(string: "zagstore://settings/diagnostics/installation")!
		case .rppairingDiagnostics:
			return URL(string: "zagstore://settings/diagnostics/installation/rppairing")!
		case .updateDiagnostics:
			return URL(string: "zagstore://settings/diagnostics/updates")!
		}
	}

	static func parse(_ url: URL) -> ZagStoreRoute? {
		guard url.scheme?.lowercased() == "zagstore" else { return nil }

		let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
			.map { $0.lowercased() }

		switch parts {
		case ["home"]: return .home
		case ["sources"]: return .sources
		case ["sources", "your-sources"]: return .yourSources
		case ["apps"]: return .apps
		case ["settings"]: return .settings
		case ["settings", "installation"]: return .installation
		case ["settings", "diagnostics", "installation"]: return .installationDiagnostics
		case ["settings", "diagnostics", "installation", "rppairing"]: return .rppairingDiagnostics
		case ["settings", "diagnostics", "updates"]: return .updateDiagnostics
		default: return nil
		}
	}
}

enum ZagStoreURL {
	static let home = ZagStoreRoute.home.url
	static let sources = ZagStoreRoute.sources.url
	static let yourSources = ZagStoreRoute.yourSources.url
	static let apps = ZagStoreRoute.apps.url
	static let settings = ZagStoreRoute.settings.url
	static let installation = ZagStoreRoute.installation.url
	static let installationDiagnostics = ZagStoreRoute.installationDiagnostics.url
	static let rppairingDiagnostics = ZagStoreRoute.rppairingDiagnostics.url
	static let updateDiagnostics = ZagStoreRoute.updateDiagnostics.url
}

enum ZagStoreRouter {
	private(set) static var pendingRoute: ZagStoreRoute?

	static func open(_ url: URL) -> Bool {
		guard let route = ZagStoreRoute.parse(url) else {
			pendingRoute = nil
			return false
		}

		pendingRoute = route
		NotificationCenter.default.post(name: .zagStoreRouteRequested, object: route)
		return true
	}

	static func consume(_ route: ZagStoreRoute) {
		if pendingRoute == route {
			pendingRoute = nil
		}
	}
}

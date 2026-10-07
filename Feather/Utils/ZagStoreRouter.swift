import Foundation

extension Notification.Name {
	static let zagStoreRouteRequested = Notification.Name("ZagStore.routeRequested")
}

enum ZagStoreRoute: String {
	case home
	case sources
	case apps
	case settings
	case installation
	case installationDiagnostics
	case rppairingDiagnostics
	case updateDiagnostics

	var tab: String {
		switch self {
		case .home: return "home"
		case .sources: return "sources"
		case .apps: return "library"
		default: return "settings"
		}
	}

	static func parse(_ url: URL) -> ZagStoreRoute? {
		guard url.scheme?.lowercased() == "zagstore" else { return nil }
		let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
			.map { $0.lowercased() }
		switch parts {
		case ["home"]: return .home
		case ["sources"]: return .sources
		case ["apps"]: return .apps
		case ["settings"]: return .settings
		case ["settings", "installation"]: return .installation

		// Canonical diagnostics hierarchy.
		case ["settings", "diagnostics", "installation"]: return .installationDiagnostics
		case ["settings", "diagnostics", "installation", "rppairing"]: return .rppairingDiagnostics
		case ["settings", "diagnostics", "updates"]: return .updateDiagnostics

		// Legacy aliases kept so existing shortcuts/links continue to work.
		case ["settings", "installation", "diagnostics"]: return .installationDiagnostics
		case ["settings", "installation", "diagnostics", "rppairing"]: return .rppairingDiagnostics
		case ["settings", "updates", "diagnostics"]: return .updateDiagnostics
		default: return nil
		}
	}
}

enum ZagStoreRouter {
	private(set) static var pendingRoute: ZagStoreRoute?

	static func open(_ url: URL) -> Bool {
		guard let route = ZagStoreRoute.parse(url) else { return false }
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

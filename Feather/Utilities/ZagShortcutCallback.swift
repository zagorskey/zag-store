import Foundation

// Temporary diagnostic: builds the documented Shortcuts x-callback-url and
// recognises Zag Store's own callbacks. Pure Foundation, so it can be tested
// on the host.
//
// Format (Shortcuts User Guide, "Use x-callback-url with Shortcuts"):
//   shortcuts://x-callback-url/run-shortcut?name=…&x-success=…&x-cancel=…&x-error=…
// Shortcuts appends `result` to x-success and `errorMessage` to x-error.

enum ZagShortcutCallback {
	static let host = "shortcut-callback"

	enum Outcome: Equatable {
		case success(run: String)
		case cancel(run: String)
		case error(run: String, message: String?)

		var run: String {
			switch self {
			case .success(let run), .cancel(let run), .error(let run, _): return run
			}
		}
	}

	/// Percent-encodes a query value strictly, so the nested callback URLs
	/// keep their own `?`, `&` and `=` intact inside the outer URL.
	static func encode(_ value: String) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
	}

	static func callbackURL(_ outcome: String, run: String) -> String {
		"zagstore://\(host)/\(outcome)?run=\(encode(run))"
	}

	static func launchURL(shortcutName: String, run: String) -> URL? {
		let query = [
			"name=\(encode(shortcutName))",
			"x-success=\(encode(callbackURL("success", run: run)))",
			"x-cancel=\(encode(callbackURL("cancel", run: run)))",
			"x-error=\(encode(callbackURL("error", run: run)))",
		].joined(separator: "&")
		return URL(string: "shortcuts://x-callback-url/run-shortcut?\(query)")
	}

	/// Returns an outcome only for Zag Store's own shortcut callbacks. Every
	/// other URL returns nil and continues through the normal routing.
	static func parse(_ url: URL) -> Outcome? {
		guard url.scheme?.lowercased() == "zagstore",
			  url.host?.lowercased() == host,
			  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			  let run = components.queryItems?.first(where: { $0.name == "run" })?.value,
			  !run.isEmpty
		else { return nil }
		switch url.path.lowercased() {
		case "/success": return .success(run: run)
		case "/cancel": return .cancel(run: run)
		case "/error":
			let message = components.queryItems?.first(where: { $0.name == "errorMessage" })?.value
			return .error(run: run, message: message)
		default: return nil
		}
	}
}

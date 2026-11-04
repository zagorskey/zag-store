import Foundation

// Protocol for the official "Zag Mobile Data Toggle" Shortcut. Pure Foundation,
// so it is tested on the host.
//
// Zag Store runs the Shortcut through Apple's documented URL scheme
// (Shortcuts User Guide, "Use x-callback-url with Shortcuts"):
//   shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=<command>
//     &x-success=…&x-cancel=…&x-error=…
// Apple documents that x-success gets a `result` parameter with the
// Shortcut's text output, and x-error gets `errorMessage`. Which parameters
// actually arrive is recorded by the controller so the device can confirm it.
//
// iOS offers no API to list a user's Shortcuts, and the URL scheme only
// accepts a name, so the Shortcut is found by name and proven by a
// handshake. A correct reply proves the Shortcut speaks this protocol; it
// does not prove its actions are unmodified.

enum ZagMobileDataToggle {
	static let shortcutName = "Zag Mobile Data Toggle"
	static let setupActionTitle = "Apply Mobile Data Fix"
	static let protocolName = "zag-mobile-data-toggle"
	static let protocolVersion = 1
	/// Stable entry point; the version-specific iCloud link lives on the page.
	static let setupPage = URL(string: "https://zagstore.app/mobile-data-fix/")!
	static let callbackHost = "shortcut-callback"
	/// A verification older than this must be repeated before it is trusted.
	static let verificationLifetime: TimeInterval = 7 * 24 * 60 * 60
	/// How long one operation may wait for its callback.
	static let operationLifetime: TimeInterval = 120

	enum Command: String, CaseIterable {
		case off, on, status

		/// The exact text the Shortcut outputs for this command.
		func expectedResult(version: Int = ZagMobileDataToggle.protocolVersion) -> String {
			switch self {
			case .status: return "\(protocolName):v\(version):ready"
			case .off, .on: return "\(protocolName):v\(version):\(rawValue):done"
			}
		}
	}

	struct Operation: Equatable {
		let id: String
		let command: Command
		let startedAt: Date
		var deadline: Date { startedAt.addingTimeInterval(operationLifetime) }

		static func new(_ command: Command, now: Date = Date()) -> Operation {
			// UUID v4: 122 random bits from the system generator.
			Operation(id: UUID().uuidString, command: command, startedAt: now)
		}
	}

	enum Outcome: String { case success, cancel, error }

	// MARK: - URLs

	/// Strict encoding so nested callback URLs keep their own `?`, `&` and `=`.
	static func encode(_ value: String) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
	}

	static func callbackURL(_ operation: Operation, _ outcome: Outcome) -> String {
		"zagstore://\(callbackHost)/\(operation.command.rawValue)/\(outcome.rawValue)?id=\(encode(operation.id))"
	}

	static func launchURL(for operation: Operation, shortcutName: String = shortcutName) -> URL? {
		let query = [
			"name=\(encode(shortcutName))",
			"input=text",
			"text=\(operation.command.rawValue)",
			"x-success=\(encode(callbackURL(operation, .success)))",
			"x-cancel=\(encode(callbackURL(operation, .cancel)))",
			"x-error=\(encode(callbackURL(operation, .error)))",
		].joined(separator: "&")
		return URL(string: "shortcuts://x-callback-url/run-shortcut?\(query)")
	}

	// MARK: - Callbacks

	struct Callback: Equatable {
		let command: Command
		let outcome: Outcome
		let id: String
		let result: String?
		let errorMessage: String?
		/// Names only, for the diagnostic record of what Shortcuts sent.
		let parameterNames: [String]
	}

	/// True for every zagstore://shortcut-callback/… URL, well-formed or not,
	/// so such URLs never fall through to the normal deep-link router.
	static func isCallback(_ url: URL) -> Bool {
		url.scheme?.lowercased() == "zagstore" && url.host?.lowercased() == callbackHost
	}

	static func parse(_ url: URL) -> Callback? {
		guard isCallback(url),
			  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else { return nil }
		let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
		guard parts.count == 2,
			  let command = Command(rawValue: parts[0]),
			  let outcome = Outcome(rawValue: parts[1])
		else { return nil }
		let items = components.queryItems ?? []
		func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
		guard let id = value("id"), !id.isEmpty else { return nil }
		return Callback(
			command: command,
			outcome: outcome,
			id: id,
			result: value("result"),
			errorMessage: value("errorMessage"),
			parameterNames: items.map(\.name)
		)
	}

	// MARK: - Responses

	enum Response: Equatable {
		case ready(version: Int)
		case done(command: Command, version: Int)
		case other
		case missing
	}

	/// Reads the Shortcut's output: `zag-mobile-data-toggle:v<N>:ready` or
	/// `zag-mobile-data-toggle:v<N>:<off|on>:done`. Anything else is `.other`.
	static func interpret(_ result: String?) -> Response {
		guard let text = result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .missing }
		let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
		guard parts.count >= 3, parts[0] == protocolName, parts[1].hasPrefix("v"),
			  let version = Int(parts[1].dropFirst()), version > 0
		else { return .other }
		if parts.count == 3, parts[2] == "ready" { return .ready(version: version) }
		if parts.count == 4, parts[3] == "done", let command = Command(rawValue: parts[2]), command != .status {
			return .done(command: command, version: version)
		}
		return .other
	}

	// MARK: - Validation

	enum Completion: Equatable {
		/// The reply matched exactly what this command should return.
		case confirmed
		/// A protocol reply from a different version of the Shortcut.
		case incompatible(found: Int)
		case missingResult
		case unexpectedResult
		case cancelled
		case failed(message: String?)
		/// Zag Store became active again without any callback.
		case noResponse
		case timedOut
		case handOffRejected
	}

	enum Decision: Equatable {
		case ignore(String)
		case complete(Completion)
	}

	/// Accepts a callback only for the one pending operation: same id, same
	/// command, within its lifetime. The caller clears the pending operation
	/// on completion, so a repeated callback is ignored.
	static func evaluate(_ callback: Callback, pending: Operation?, now: Date = Date()) -> Decision {
		guard let pending else { return .ignore("no operation is waiting") }
		guard callback.id == pending.id else { return .ignore("it does not match the current operation") }
		guard callback.command == pending.command else { return .ignore("it is for a different command") }
		guard now <= pending.deadline else { return .ignore("the operation has expired") }

		switch callback.outcome {
		case .cancel: return .complete(.cancelled)
		case .error: return .complete(.failed(message: callback.errorMessage))
		case .success: break
		}
		switch (pending.command, interpret(callback.result)) {
		case (_, .missing):
			return .complete(.missingResult)
		case (.status, .ready(let version)):
			return .complete(version == protocolVersion ? .confirmed : .incompatible(found: version))
		case (let command, .done(let done, let version)) where command == done:
			return .complete(version == protocolVersion ? .confirmed : .incompatible(found: version))
		default:
			return .complete(.unexpectedResult)
		}
	}

	// MARK: - Stored setup state

	struct Record: Codable, Equatable {
		var setupPageOpenedAt: Date?
		var verifiedAt: Date?
		var verifiedVersion: Int?
		var failure: String?
		var failedAt: Date?
		var updateRequiredVersion: Int?
	}

	enum Status: Equatable {
		case notSetUp
		case verificationRequired(reason: String)
		case verified(version: Int, at: Date)
		case failed(reason: String)
		case updateRequired(found: Int)

		var title: String {
			switch self {
			case .notSetUp: return "Not Set Up"
			case .verificationRequired: return "Verification Required"
			case .verified: return "Verified"
			case .failed: return "Verification Failed"
			case .updateRequired: return "Update Required"
			}
		}

		var isVerified: Bool {
			if case .verified = self { return true }
			return false
		}
	}

	static func status(of record: Record, now: Date = Date()) -> Status {
		if let found = record.updateRequiredVersion { return .updateRequired(found: found) }
		if let failure = record.failure, let failedAt = record.failedAt,
		   record.verifiedAt.map({ failedAt >= $0 }) ?? true {
			return .failed(reason: failure)
		}
		if let at = record.verifiedAt, record.verifiedVersion == protocolVersion {
			if now.timeIntervalSince(at) <= verificationLifetime, at <= now.addingTimeInterval(60) {
				return .verified(version: protocolVersion, at: at)
			}
			return .verificationRequired(reason: "The last verification is more than 7 days old.")
		}
		if record.verifiedAt != nil {
			return .verificationRequired(reason: "This version of Zag Store needs the Shortcut verified again.")
		}
		if record.setupPageOpenedAt != nil {
			return .verificationRequired(reason: "After adding \(shortcutName), verify it here.")
		}
		return .notSetUp
	}

	/// How a finished operation changes the stored state. A cancellation
	/// changes nothing; every other failure withdraws Verified.
	static func record(_ record: Record, after completion: Completion, now: Date = Date()) -> Record {
		var next = record
		switch completion {
		case .confirmed:
			next.verifiedAt = now
			next.verifiedVersion = protocolVersion
			next.failure = nil
			next.failedAt = nil
			next.updateRequiredVersion = nil
		case .incompatible(let found):
			next.updateRequiredVersion = found
			next.failure = nil
			next.failedAt = nil
		case .cancelled:
			break
		default:
			next.failure = message(for: completion)
			next.failedAt = now
			next.updateRequiredVersion = nil
		}
		return next
	}

	static func message(for completion: Completion) -> String {
		switch completion {
		case .confirmed:
			return "\(shortcutName) replied correctly."
		case .incompatible(let found):
			return found < protocolVersion
				? "\(shortcutName) is an older version (v\(found)). Get the current version from zagstore.app."
				: "\(shortcutName) is newer (v\(found)) than this Zag Store supports. Update Zag Store."
		case .missingResult:
			return "\(shortcutName) finished without a reply. It may be modified or out of date."
		case .unexpectedResult:
			return "\(shortcutName) sent an unexpected reply. It may be modified or out of date."
		case .cancelled:
			return "Cancelled in Shortcuts."
		case .failed(let message):
			let detail = message.map { String($0.prefix(160)) }
			return "Shortcuts could not run \(shortcutName)\(detail.map { ": \($0)" } ?? ""). Make sure it is installed with this exact name."
		case .noResponse:
			return "Zag Store returned without a reply from Shortcuts."
		case .timedOut:
			return "Shortcuts did not reply in time."
		case .handOffRejected:
			return "iOS could not open the Shortcuts app."
		}
	}
}

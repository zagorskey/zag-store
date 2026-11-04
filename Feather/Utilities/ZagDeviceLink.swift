import Foundation

/// The LocalDevVPN loopback that Zag Store uses to reach the iPhone's own
/// device services. Nothing here depends on Wi-Fi: traffic to the peer
/// address is routed into the VPN's tunnel and never reaches a physical
/// interface, so it behaves the same on Wi-Fi, 4G and 5G.
///
/// Pure Foundation so host-side tests can compile it directly.
enum ZagDeviceLink {
	static let peerAddress = "10.7.0.1"
	/// Experimental: this iPhone's own loopback address, used only by the
	/// loopback health check in RPPairing Diagnostics.
	static let loopbackAddress = "127.0.0.1"
	static let lockdownPort: UInt16 = 62078
	static let rsdPort: UInt16 = 49152
}

// MARK: - Lockdown QueryType

/// Builds and parses the unauthenticated lockdown `QueryType` exchange:
/// a 4-byte big-endian length followed by a property list, the same framing
/// IDeviceKitten uses. A valid reply proves lockdownd answered, which a TCP
/// handshake alone does not.
enum ZagLockdownQuery {
	static let expectedType = "com.apple.mobile.lockdown"
	/// Replies to QueryType are a few hundred bytes. Anything far larger is
	/// not lockdown and is rejected rather than buffered.
	static let maximumReplyLength = 64 * 1024

	enum Reply: Equatable {
		case needMoreData
		case lockdown
		case invalid(String)
	}

	static func request(label: String = "ZagStore") -> Data {
		let message: [String: String] = ["Label": label, "Request": "QueryType"]
		// Serialising a fixed [String: String] dictionary cannot fail.
		let body = (try? PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)) ?? Data()
		var length = UInt32(body.count).bigEndian
		var frame = Data(bytes: &length, count: 4)
		frame.append(body)
		return frame
	}

	/// Parses whatever has been received so far.
	static func parse(_ received: Data) -> Reply {
		guard received.count >= 4 else { return .needMoreData }
		let bytes = [UInt8](received.prefix(4))
		let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
		guard length > 0, length <= maximumReplyLength else {
			return .invalid("Unexpected reply length \(length)")
		}
		guard received.count >= 4 + length else { return .needMoreData }
		let body = received.subdata(in: 4..<(4 + length))
		guard let plist = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil),
			  let dictionary = plist as? [String: Any] else {
			return .invalid("Reply is not a property list")
		}
		guard let type = dictionary["Type"] as? String else {
			if let error = dictionary["Error"] as? String { return .invalid("lockdownd error: \(error)") }
			return .invalid("Reply has no Type")
		}
		return type == expectedType ? .lockdown : .invalid("Unexpected service type \(type)")
	}
}

// MARK: - Status model

/// Why a device-service probe did not succeed.
enum ZagDeviceProbeFailure: Equatable {
	case refused
	case timedOut
	/// The connection never started; iOS reported why (for example a policy
	/// that blocks this app's network access).
	case waiting(String)
	case reset
	case invalidResponse(String)
	case failed(String)

	var summary: String {
		switch self {
		case .refused: return "Connection refused"
		case .timedOut: return "No response"
		case .waiting(let reason): return "Connection waiting: \(reason)"
		case .reset: return "Connection reset"
		case .invalidResponse(let reason): return "Unexpected response: \(reason)"
		case .failed(let reason): return reason
		}
	}
}

/// Result of the optional legacy lockdown QueryType on port 62078. This is
/// diagnostic evidence only: the RPPairing transport never uses that port,
/// and on iOS 17+ the device may reset or refuse it while RPPairing works.
enum ZagDeviceProbeResult: Equatable {
	case lockdownReachable(milliseconds: Int)
	case failed(ZagDeviceProbeFailure)
}

/// Result of a connect-only check of the RemotePairing endpoint
/// (10.7.0.1:49152), the first connection every RPPairing session makes.
enum ZagEndpointProbeResult: Equatable {
	case accepted(milliseconds: Int)
	case failed(ZagDeviceProbeFailure)

	/// A refusal or reset is an answer from the iPhone's own network stack,
	/// so the tunnel carried the packet even though nothing accepted it.
	var deviceAnswered: Bool {
		switch self {
		case .accepted: return true
		case .failed(let failure): return failure == .refused || failure == .reset
		}
	}
}

/// Where an RPPairing session makes its two outer TCP connections (49152,
/// then the TLS-PSK tunnel port). Everything after that, RSD and the
/// installation services, runs inside the encrypted tunnel on addresses the
/// iPhone assigns, so this is the only transport choice.
///
/// Production paths always use `.localDevVPN`. `.loopbackExperimental` is
/// only offered by the diagnostics screen, for one health check at a time.
enum ZagRPPairingEndpoint: Equatable {
	case localDevVPN
	case loopbackExperimental

	var address: String {
		switch self {
		case .localDevVPN: return ZagDeviceLink.peerAddress
		case .loopbackExperimental: return ZagDeviceLink.loopbackAddress
		}
	}

	var label: String {
		switch self {
		case .localDevVPN: return "LocalDevVPN"
		case .loopbackExperimental: return "Loopback (experimental)"
		}
	}

	/// Only the production transport may update the toolbar's RPPairing
	/// state. A loopback success says nothing about the tunnel.
	var publishesReadiness: Bool { self == .localDevVPN }

	/// Accepts only the two known addresses.
	static func validated(_ address: String) -> ZagRPPairingEndpoint? {
		switch address {
		case ZagDeviceLink.peerAddress: return .localDevVPN
		case ZagDeviceLink.loopbackAddress: return .loopbackExperimental
		default: return nil
		}
	}
}

/// The outcome of a real RPPairing session (health check or installation).
enum ZagRPPairingReadiness: Equatable {
	case unknown
	case verified(Date)
	case failed(ZagRPPairingFailureKind, Date)
}

// MARK: - Status model

/// Three independent layers, each with explicit "not checked" semantics.
enum ZagTunnelState: Equatable {
	case unknown
	/// A LocalDevVPN-style interface exists, but nothing has answered yet.
	case interfaceDetected
	/// The iPhone answered through the tunnel (accepted, refused or reset).
	case operational
	/// No tunnel interface and no answer.
	case disconnected
}

enum ZagServiceState: Equatable {
	case notChecked
	/// The RemotePairing endpoint accepted a connection.
	case reachable(Date)
	/// The iPhone answered but did not accept (refused or reset).
	case unreachable(ZagDeviceProbeFailure, Date)
	/// Nothing answered within the timeout.
	case noResponse(ZagDeviceProbeFailure, Date)

	var date: Date? {
		switch self {
		case .notChecked: return nil
		case .reachable(let date), .unreachable(_, let date), .noResponse(_, let date): return date
		}
	}
}

enum ZagPairingState: Equatable {
	case notChecked
	case verified(Date)
	case failed(ZagRPPairingFailureKind, Date)
	/// Verified earlier, but the network changed, the tunnel dropped or the
	/// result expired. Shown as history, not as current readiness.
	case awaitingRevalidation(lastSuccess: Date)

	var date: Date? {
		switch self {
		case .notChecked: return nil
		case .verified(let date), .failed(_, let date), .awaitingRevalidation(let date): return date
		}
	}
}

enum ZagLinkIndicator: Equatable {
	/// The RemotePairing endpoint accepted a connection in the latest check,
	/// or a real RPPairing session verified more recently than any failure.
	case on
	/// A confirmed failure: the iPhone refused or reset the endpoint, or the
	/// latest real session failed after the endpoint was last reachable.
	case warning
	/// No tunnel, or no reliable status yet.
	case off
	/// A check is running and nothing has been established yet.
	case checking
}

/// Pure state for the Local VPN indicator. Every input carries the time it
/// was observed, and older evidence never replaces newer evidence.
struct ZagDeviceLinkModel: Equatable {
	/// A verified RPPairing session is trusted for this long without a new
	/// session, after which it is shown as awaiting revalidation.
	static let pairingFreshness: TimeInterval = 10 * 60

	private(set) var tunnel: ZagTunnelState = .unknown
	private(set) var service: ZagServiceState = .notChecked
	private(set) var pairing: ZagPairingState = .notChecked
	private(set) var checking = false
	private(set) var physicalNetwork: String?
	private(set) var lastResponseMilliseconds: Int?

	mutating func probeStarted() {
		checking = true
	}

	/// A probe that ran from `startedAt` to `finishedAt`. If a real session
	/// produced evidence while it ran, that evidence is newer and wins.
	mutating func probeFinished(_ result: ZagEndpointProbeResult, interfacePresent: Bool, startedAt: Date, finishedAt: Date) {
		checking = false
		if let evidence = pairing.date, evidence > startedAt, case .verified = pairing { return }
		switch result {
		case .accepted(let milliseconds):
			tunnel = .operational
			service = .reachable(finishedAt)
			lastResponseMilliseconds = milliseconds
		case .failed(let failure):
			if result.deviceAnswered {
				tunnel = .operational
				service = .unreachable(failure, finishedAt)
			} else {
				tunnel = interfacePresent ? .interfaceDetected : .disconnected
				service = .noResponse(failure, finishedAt)
				if tunnel == .disconnected { invalidatePairing() }
			}
		}
	}

	/// A probe was skipped or abandoned (app inactive, transport busy).
	mutating func probeAbandoned() {
		checking = false
	}

	/// Evidence from a real RPPairing session.
	mutating func pairingEvent(_ readiness: ZagRPPairingReadiness) {
		switch readiness {
		case .unknown:
			return
		case .verified(let date):
			guard isNewer(date) else { return }
			pairing = .verified(date)
			// A verified session connected to the endpoint, so it was reachable.
			tunnel = .operational
			if (service.date ?? .distantPast) < date { service = .reachable(date) }
		case .failed(let kind, let date):
			guard isNewer(date) else { return }
			pairing = .failed(kind, date)
		}
	}

	/// The physical network changed (Wi-Fi, cellular, none). A verified
	/// session no longer proves the new path works.
	mutating func networkChanged(to network: String?) {
		if physicalNetwork != nil, network != physicalNetwork { invalidatePairing() }
		physicalNetwork = network
	}

	mutating func expire(now: Date) {
		if case .verified(let date) = pairing, now.timeIntervalSince(date) > Self.pairingFreshness {
			pairing = .awaitingRevalidation(lastSuccess: date)
		}
	}

	var indicator: ZagLinkIndicator {
		// A real session failure newer than the last time the endpoint was
		// reachable is a confirmed problem, even if the port still accepts.
		if case .failed(let kind, let date) = pairing, kind != .installation, kind != .other,
		   date >= (service.date ?? .distantPast) {
			return .warning
		}
		switch service {
		case .reachable: return .on
		case .unreachable: return .warning
		case .noResponse: return .off
		case .notChecked:
			if case .verified = pairing { return .on }
			return checking ? .checking : .off
		}
	}

	/// Seconds until the next automatic check: frequent while not ON,
	/// relaxed once ON.
	var pollInterval: TimeInterval {
		indicator == .on ? 60 : 12
	}

	/// True when a failed endpoint probe shows the tunnel is gone: nothing
	/// answered and no tunnel interface exists. Used to stop retries early.
	static func tunnelIsDown(_ result: ZagEndpointProbeResult, interfacePresent: Bool) -> Bool {
		!result.deviceAnswered && !interfacePresent
	}

	private func isNewer(_ date: Date) -> Bool {
		date >= (pairing.date ?? .distantPast)
	}

	private mutating func invalidatePairing() {
		if case .verified(let date) = pairing { pairing = .awaitingRevalidation(lastSuccess: date) }
	}
}

// MARK: - Tunnel interface

enum ZagTunnelInterface {
	/// LocalDevVPN puts its own end of the tunnel in 10.7.0.0/16 (10.7.1.1 by
	/// default; StosVPN used 10.7.0.0) on a utun interface.
	static func isLocalDevTunnel(name: String, ipv4: String) -> Bool {
		guard name.hasPrefix("utun") else { return false }
		let parts = ipv4.split(separator: ".").compactMap { Int($0) }
		return parts.count == 4 && parts[0] == 10 && parts[1] == 7
	}

	static func containsLocalDevTunnel(_ interfaces: [(name: String, ipv4: String)]) -> Bool {
		interfaces.contains { isLocalDevTunnel(name: $0.name, ipv4: $0.ipv4) }
	}

	/// The device's current IPv4 interfaces.
	static func current() -> [(name: String, ipv4: String)] {
		var result: [(name: String, ipv4: String)] = []
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0, let first = head else { return result }
		defer { freeifaddrs(head) }
		var cursor: UnsafeMutablePointer<ifaddrs>? = first
		while let entry = cursor {
			defer { cursor = entry.pointee.ifa_next }
			guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
							  nil, 0, NI_NUMERICHOST) == 0 else { continue }
			result.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
		}
		return result
	}
}

// MARK: - Probe scheduling

/// Serialises device-service probes. One probe runs at a time; a request that
/// arrives meanwhile is remembered and runs as soon as the current probe ends,
/// so a network change is never lost. Results from a cancelled or superseded
/// probe are ignored by generation.
struct ZagDeviceProbeScheduler: Equatable {
	private(set) var generation = 0
	private(set) var running: Int?
	private(set) var recheckPending = false

	/// Returns the generation to probe now, or nil if one is already running
	/// (the request is then queued).
	mutating func request() -> Int? {
		guard running == nil else {
			recheckPending = true
			return nil
		}
		generation += 1
		running = generation
		return generation
	}

	/// A probe finished. `accepted` says whether its result may be shown;
	/// `next` is a queued re-check to start immediately.
	mutating func finish(_ candidate: Int) -> (accepted: Bool, next: Int?) {
		guard candidate == running else { return (false, nil) }
		running = nil
		guard recheckPending else { return (true, nil) }
		recheckPending = false
		generation += 1
		running = generation
		return (true, generation)
	}

	/// Abandons the running probe (the app left the foreground). Its result
	/// will be ignored and nothing stays queued.
	mutating func cancel() {
		running = nil
		recheckPending = false
		generation += 1
	}
}

// MARK: - RPPairing failures

enum ZagRPPairingFailureKind: Equatable {
	/// The saved pairing file is missing or unreadable.
	case pairingFile
	/// The device address could not be reached before any session started.
	case deviceUnreachable
	/// A connection dropped while setting up the session (before installing).
	case connectionInterrupted
	/// The iPhone rejected the saved pairing credentials.
	case pairingRejected
	/// The secure tunnel or service discovery failed after verification.
	case sessionSetup
	/// The failure happened after installation began on the device.
	case installation
	case other
}

/// Classifies the Rust core's error text. The prefixes come from
/// RPPairingCore/rust-core/src/lib.rs and are stable.
enum ZagRPPairingFailure {
	static func classify(_ message: String, installationStarted: Bool) -> ZagRPPairingFailureKind {
		if installationStarted { return .installation }
		let text = message.lowercased()
		if text.contains("saved rppairing credentials") && text.contains("unable to read") { return .pairingFile }
		if text.contains("timed out reaching rppairing at") || text.contains("unable to reach rppairing at") {
			return .deviceUnreachable
		}
		if text.contains("pair-verify failed") {
			return isConnectionLoss(text) ? .connectionInterrupted : .pairingRejected
		}
		if text.contains("createlistener failed") || text.contains("rppairing tunnel at")
			|| text.contains("tls-psk cdtunnel failed") || text.contains("rsd handshake failed")
			|| text.contains("installation_proxy over rsd failed") || text.contains("user-app lookup failed") {
			return isConnectionLoss(text) ? .connectionInterrupted : .sessionSetup
		}
		return .other
	}

	/// Only failures that happened before anything changed on the device, and
	/// that look like the network rather than the credentials, are retried.
	static func isRetryable(_ kind: ZagRPPairingFailureKind) -> Bool {
		switch kind {
		case .deviceUnreachable, .connectionInterrupted, .sessionSetup: return true
		case .pairingFile, .pairingRejected, .installation, .other: return false
		}
	}

	/// Whether the user should be offered to pair again. Network problems
	/// never touch the pairing file.
	static func suggestsRepairing(_ kind: ZagRPPairingFailureKind) -> Bool {
		kind == .pairingFile || kind == .pairingRejected
	}

	static func explanation(_ kind: ZagRPPairingFailureKind) -> String {
		switch kind {
		case .pairingFile:
			return "The saved pairing file is missing or unreadable. Import or create a pairing file, then try again."
		case .deviceUnreachable:
			return "Zag Store could not reach the iPhone's device services at \(ZagDeviceLink.peerAddress). Check that LocalDevVPN is connected, then try again."
		case .connectionInterrupted:
			return "The connection to the iPhone's device services closed before installation began, for example during a network change. Nothing was installed."
		case .pairingRejected:
			return "The iPhone rejected the saved pairing credentials. You may need to pair Zag Store again."
		case .sessionSetup:
			return "The secure device session could not be set up. Nothing was installed. Try again; if it persists, check LocalDevVPN."
		case .installation:
			return "The connection failed after installation began on the iPhone. Zag Store does not retry this automatically; check whether the app installed, then try again."
		case .other:
			return "The installation could not be completed."
		}
	}

	static func isConnectionLoss(_ text: String) -> Bool {
		["socket io", "connection reset", "broken pipe", "unexpected eof", "connection aborted", "timed out", "os error 54", "os error 32"]
			.contains { text.contains($0) }
	}
}

/// Decides whether a failed install attempt may run again. Attempts are
/// counted per install, and a new install cannot begin while one is active.
struct ZagGate4RetryPlan: Equatable {
	static let delays: [TimeInterval] = [1, 3]
	private(set) var active = false
	private(set) var retriesUsed = 0

	/// Starts a new install. Returns false if one is already active.
	mutating func begin() -> Bool {
		guard !active else { return false }
		active = true
		retriesUsed = 0
		return true
	}

	/// After a failure: the delay before retrying, or nil to give up.
	mutating func delayAfterFailure(_ kind: ZagRPPairingFailureKind) -> TimeInterval? {
		guard active else { return nil }
		guard ZagRPPairingFailure.isRetryable(kind), retriesUsed < Self.delays.count else {
			active = false
			return nil
		}
		let delay = Self.delays[retriesUsed]
		retriesUsed += 1
		return delay
	}

	mutating func end() {
		active = false
	}
}

// MARK: - Diagnostic report

/// One recorded step of a real RPPairing session.
struct ZagDiagnosticStep: Equatable {
	let stage: String
	let detail: String
	let elapsedMilliseconds: Int
	let failed: Bool
}

/// Builds a plain-text, redacted report for physical-device testing. It
/// never includes the device name, UDIDs, serials, keys or pairing data.
enum ZagDiagnosticReport {
	struct Input {
		var generatedAt: Date
		var iOSVersion: String
		var deviceModel: String
		var physicalNetworks: [String]
		var tunnelInterfaces: [String]
		var model: ZagDeviceLinkModel
		var endpointProbe: ZagEndpointProbeResult?
		var legacyLockdownProbe: ZagDeviceProbeResult?
		var steps: [ZagDiagnosticStep]
		var sessionFailure: String?
		var endpoint: ZagRPPairingEndpoint = .localDevVPN
	}

	/// The OS error number in a Rust I/O error message, e.g. 61 for
	/// "Connection refused (os error 61)".
	static func osErrorCode(_ message: String) -> Int? {
		guard let range = message.range(of: "os error ", options: .caseInsensitive) else { return nil }
		let digits = message[range.upperBound...].prefix { $0.isNumber }
		return Int(digits)
	}

	static func make(_ input: Input) -> String {
		let time = ISO8601DateFormatter()
		var lines: [String] = []
		lines.append("Zag Store RPPairing diagnostic report")
		lines.append("Generated: \(time.string(from: input.generatedAt))")
		lines.append("Device: \(input.deviceModel), iOS \(input.iOSVersion)")
		lines.append("Physical network: \(input.physicalNetworks.isEmpty ? "none" : input.physicalNetworks.joined(separator: ", "))")
		lines.append("Tunnel interfaces (10.7.x.x): \(input.tunnelInterfaces.isEmpty ? "none" : input.tunnelInterfaces.joined(separator: ", "))")
		lines.append("Target endpoint: \(input.endpoint.address):\(ZagDeviceLink.rsdPort) (RemotePairing, \(input.endpoint.label))")
		lines.append("")
		lines.append("Toolbar: \(describe(input.model.indicator))")
		lines.append("Tunnel: \(describe(input.model.tunnel))")
		lines.append("Device service: \(describe(input.model.service))")
		lines.append("RPPairing: \(describe(input.model.pairing))")
		if let probe = input.endpointProbe {
			lines.append("RemotePairing endpoint check: \(describe(probe))")
		}
		if let legacy = input.legacyLockdownProbe {
			lines.append("Legacy lockdown \(ZagDeviceLink.lockdownPort) QueryType (informational, not used by RPPairing): \(describe(legacy))")
		}
		lines.append("")
		if input.steps.isEmpty {
			lines.append("Health check: not run this session")
		} else {
			lines.append("Health check steps:")
			for step in input.steps {
				lines.append("  [\(step.elapsedMilliseconds) ms] \(step.failed ? "FAILED " : "")\(step.stage): \(step.detail)")
			}
			if let last = input.steps.last { lines.append("Total duration: \(last.elapsedMilliseconds) ms") }
			if let failure = input.sessionFailure {
				let kind = ZagRPPairingFailure.classify(failure, installationStarted: false)
				lines.append("First failing operation: \(input.steps.last { $0.failed }?.stage ?? "unknown")")
				lines.append("Failure category: \(kind)")
				if let code = osErrorCode(failure) { lines.append("Error code: OS error \(code)") }
			}
		}
		return redact(lines.joined(separator: "\n"))
	}

	/// Removes long hexadecimal identifiers (UDIDs, ECIDs, key material),
	/// UUIDs and email addresses.
	static func redact(_ text: String) -> String {
		var result = text
		let patterns = [
			"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
			"\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\\b",
			"\\b[0-9A-Fa-f]{20,}\\b",
			"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
		]
		for pattern in patterns {
			result = result.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
		}
		return result
	}

	static func describe(_ indicator: ZagLinkIndicator) -> String {
		switch indicator {
		case .on: return "ON"
		case .warning: return "! (confirmed failure)"
		case .off: return "— (no tunnel or no reliable status)"
		case .checking: return "… (checking)"
		}
	}

	static func describe(_ tunnel: ZagTunnelState) -> String {
		switch tunnel {
		case .unknown: return "Unknown"
		case .interfaceDetected: return "Interface detected, no answer yet"
		case .operational: return "Operational (the iPhone answered through it)"
		case .disconnected: return "Disconnected"
		}
	}

	static func describe(_ service: ZagServiceState) -> String {
		switch service {
		case .notChecked: return "Not checked"
		case .reachable: return "Reachable (connection accepted)"
		case .unreachable(let failure, _): return "Unreachable: \(failure.summary)"
		case .noResponse(let failure, _): return "No response: \(failure.summary)"
		}
	}

	static func describe(_ pairing: ZagPairingState) -> String {
		let time = ISO8601DateFormatter()
		switch pairing {
		case .notChecked: return "Not checked"
		case .verified(let date): return "Verified at \(time.string(from: date))"
		case .failed(let kind, let date): return "Failed (\(kind)) at \(time.string(from: date))"
		case .awaitingRevalidation(let date): return "Previous success at \(time.string(from: date)), awaiting revalidation"
		}
	}

	static func describe(_ probe: ZagEndpointProbeResult) -> String {
		switch probe {
		case .accepted(let ms): return "accepted in \(ms) ms"
		case .failed(let failure): return failure.summary
		}
	}

	static func describe(_ probe: ZagDeviceProbeResult) -> String {
		switch probe {
		case .lockdownReachable(let ms): return "valid reply in \(ms) ms"
		case .failed(let failure): return failure.summary
		}
	}
}

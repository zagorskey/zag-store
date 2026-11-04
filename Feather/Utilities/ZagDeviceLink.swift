import Foundation

/// The LocalDevVPN loopback that Zag Store uses to reach the iPhone's own
/// device services. Nothing here depends on Wi-Fi: traffic to the peer
/// address is routed into the VPN's tunnel and never reaches a physical
/// interface, so it behaves the same on Wi-Fi, 4G and 5G.
///
/// Pure Foundation so host-side tests can compile it directly.
enum ZagDeviceLink {
	static let peerAddress = "10.7.0.1"
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

enum ZagDeviceProbeResult: Equatable {
	case lockdownReachable(milliseconds: Int)
	case failed(ZagDeviceProbeFailure)
}

/// What the toolbar shows. The three layers stay separate:
/// tunnel present, device service answering, and RPPairing verified.
enum ZagDeviceLinkStatus: Equatable {
	case checking
	/// No tunnel interface carries the LocalDevVPN address.
	case tunnelUnavailable
	/// The tunnel looks present but lockdownd did not answer properly.
	case serviceUnreachable(ZagDeviceProbeFailure)
	case reachable(milliseconds: Int)

	var isReachable: Bool {
		if case .reachable = self { return true }
		return false
	}
}

/// The outcome of the most recent real RPPairing session, taken from an
/// install or health probe. The toolbar never runs a handshake to fill it.
enum ZagRPPairingReadiness: Equatable {
	case unknown
	case verified(Date)
	case failed(ZagRPPairingFailureKind, Date)
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

/// Pure status transitions used by the monitor.
enum ZagDeviceLinkTransitions {
	/// While already ON, a re-check keeps showing ON instead of flickering
	/// to "checking".
	static func statusWhileChecking(_ current: ZagDeviceLinkStatus) -> ZagDeviceLinkStatus {
		current.isReachable ? current : .checking
	}

	static func status(tunnelPresent: Bool, probe: ZagDeviceProbeResult?) -> ZagDeviceLinkStatus {
		switch probe {
		case .lockdownReachable(let milliseconds)?:
			return .reachable(milliseconds: milliseconds)
		case .failed(let failure)?:
			// A refused or timed-out connection with no tunnel interface means
			// LocalDevVPN is off. With the interface present it means the
			// device service itself did not answer.
			if !tunnelPresent, failure == .refused || failure == .timedOut { return .tunnelUnavailable }
			if !tunnelPresent, case .waiting = failure { return .tunnelUnavailable }
			return .serviceUnreachable(failure)
		case nil:
			return tunnelPresent ? .checking : .tunnelUnavailable
		}
	}

	/// Seconds until the next automatic check: frequent while not reachable,
	/// relaxed once ON.
	static func pollInterval(for status: ZagDeviceLinkStatus) -> TimeInterval {
		status.isReachable ? 60 : 12
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

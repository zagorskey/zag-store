import Foundation
import Network

// Developer diagnostic: locates where a connection to the RemotePairing
// endpoint fails, using only public APIs and a fixed set of connections.
//
// LocalDevVPN does not forward traffic anywhere. Its tunnel swaps the IPv4
// source and destination of every packet and writes it back, so a SYN sent to
// 10.7.0.1:P re-enters this iPhone's own TCP stack addressed to the tunnel
// address (for example 10.7.1.1:P). Every answer therefore comes from this
// iPhone. The trace separates:
// - whether TCP crosses the tunnel at all (our own listener, reached through it);
// - whether a listener that excludes cellular is reached through it;
// - how the RemotePairing port answers through the tunnel, directly on the
//   tunnel address, and on loopback.
// Nothing is sent on any connection; no pairing data is read or logged.

struct ZagTraceStep: Equatable {
	let name: String
	let outcome: String
	let milliseconds: Int
}

/// What the peer does with a connection on which nothing is sent.
enum ZagIdleOutcome: Equatable {
	/// Still open when the wait ended: the service is waiting for a request.
	case stillOpen(waitedMilliseconds: Int)
	/// The peer closed the connection (end of stream) without any request.
	case closedByPeer(milliseconds: Int)
	/// The peer reset the connection without any request.
	case reset(milliseconds: Int)
	/// The peer sent bytes first (count only).
	case dataReceived(bytes: Int, milliseconds: Int)
	/// The connection was never established.
	case notConnected(ZagDeviceProbeFailure)

	var rejectsWithoutRequest: Bool {
		switch self {
		case .closedByPeer, .reset: return true
		default: return false
		}
	}
}

struct ZagTransportTraceResult: Equatable {
	var systemNetworks: [String] = []
	var systemPathExpensive: Bool?
	var tunnelInterfaces: [String] = []
	var tunnelAddress: String?
	/// Local address the routing table picks for the peer address.
	var routeSource: String?
	/// Interfaces Network.framework reports for a path to the peer.
	var peerPathInterfaces: [String] = []
	var peerPathUsesCellular: Bool?
	var peerPathUsesWiFi: Bool?
	var peerPathExpensive: Bool?
	/// Our own unrestricted listener, reached through the tunnel.
	var tunnelLoopback: ZagEndpointProbeResult?
	/// Our own listener that prohibits cellular, reached through the tunnel.
	var tunnelLoopbackNoCellular: ZagEndpointProbeResult?
	var remotePairingViaTunnel: ZagEndpointProbeResult?
	var remotePairingDirect: ZagEndpointProbeResult?
	var remotePairingLoopback: ZagEndpointProbeResult?
	/// Idle connections to the RemotePairing port: nothing is sent.
	var idleViaTunnel: ZagIdleOutcome?
	var idleLoopback: ZagIdleOutcome?
	var steps: [ZagTraceStep] = []
	var skipped: String?
}

enum ZagTransportTrace {
	static func run(
		peer: String = ZagDeviceLink.peerAddress,
		servicePort: UInt16 = ZagDeviceLink.rsdPort,
		tunnelAddress overrideAddress: String? = nil,
		timeout: TimeInterval = 2,
		idleWait: TimeInterval = 3
	) async -> ZagTransportTraceResult {
		var result = ZagTransportTraceResult()
		let clock = ProcessInfo.processInfo.systemUptime
		func step(_ name: String, _ outcome: String) {
			result.steps.append(ZagTraceStep(
				name: name, outcome: outcome,
				milliseconds: Int((ProcessInfo.processInfo.systemUptime - clock) * 1000)
			))
		}

		let system = await systemPath()
		result.systemNetworks = system.networks
		result.systemPathExpensive = system.expensive
		step("System path", system.networks.isEmpty ? "no physical network" : system.networks.joined(separator: ", "))

		let tunnels = ZagTunnelInterface.current().filter { ZagTunnelInterface.isLocalDevTunnel(name: $0.name, ipv4: $0.ipv4) }
		result.tunnelInterfaces = tunnels.map { "\($0.name) \($0.ipv4)" }
		result.tunnelAddress = overrideAddress ?? tunnels.first?.ipv4
		step("Tunnel interface", result.tunnelInterfaces.isEmpty ? "none" : result.tunnelInterfaces.joined(separator: ", "))

		result.routeSource = routeSource(to: peer)
		step("Route source for \(peer)", result.routeSource ?? "no route")

		let path = await peerPath(peer)
		result.peerPathInterfaces = path.interfaces
		result.peerPathUsesCellular = path.cellular
		result.peerPathUsesWiFi = path.wifi
		result.peerPathExpensive = path.expensive
		step("Path to \(peer)", path.interfaces.isEmpty ? "unavailable" : path.interfaces.joined(separator: ", "))

		result.tunnelLoopback = await loopback(peer: peer, prohibitCellular: false, timeout: timeout)
		step("Own listener via tunnel", describe(result.tunnelLoopback))
		result.tunnelLoopbackNoCellular = await loopback(peer: peer, prohibitCellular: true, timeout: timeout)
		step("Own no-cellular listener via tunnel", describe(result.tunnelLoopbackNoCellular))

		result.remotePairingViaTunnel = await ZagEndpointProbe.connect(host: peer, port: servicePort, timeout: timeout)
		step("RemotePairing \(peer):\(servicePort)", describe(result.remotePairingViaTunnel))
		if let address = result.tunnelAddress {
			result.remotePairingDirect = await ZagEndpointProbe.connect(host: address, port: servicePort, timeout: timeout)
			step("RemotePairing \(address):\(servicePort) (direct)", describe(result.remotePairingDirect))
		}
		result.remotePairingLoopback = await ZagEndpointProbe.connect(host: "127.0.0.1", port: servicePort, timeout: timeout)
		step("RemotePairing 127.0.0.1:\(servicePort)", describe(result.remotePairingLoopback))

		result.idleViaTunnel = await idle(host: peer, port: servicePort, connectTimeout: timeout, wait: idleWait)
		step("Idle \(peer):\(servicePort), nothing sent", describe(result.idleViaTunnel))
		result.idleLoopback = await idle(host: "127.0.0.1", port: servicePort, connectTimeout: timeout, wait: idleWait)
		step("Idle 127.0.0.1:\(servicePort), nothing sent", describe(result.idleLoopback))
		return result
	}

	// MARK: Interpretation

	/// Plain conclusions that follow from the observed results. Each one says
	/// whether it is an observation or an inference.
	static func findings(_ r: ZagTransportTraceResult) -> [String] {
		if let skipped = r.skipped { return ["Trace skipped: \(skipped)"] }
		var out: [String] = []
		if r.tunnelInterfaces.isEmpty {
			out.append("Observed: no LocalDevVPN interface (utun with a 10.7.x.x address). Results below cannot involve the tunnel.")
		}
		if r.peerPathUsesCellular == true {
			out.append("Observed: iOS reports the path to the peer as using cellular, so the tunnel is treated as running over cellular.")
		}

		let tunnelWorks: Bool
		switch r.tunnelLoopback {
		case .accepted?:
			tunnelWorks = true
			out.append("Observed: TCP crosses the tunnel in both directions. A connection to the peer address came back reflected and was accepted by Zag Store's own listener, so the SYN does reach LocalDevVPN and is returned (cases A and B ruled out on this network).")
		case .failed(let failure)?:
			tunnelWorks = false
			if failure == .refused || failure == .reset {
				out.append("Observed: even Zag Store's own unrestricted listener was \(failure.summary.lowercased()) through the tunnel. The tunnel returns packets but they are not delivered to listeners on this network.")
			} else {
				out.append("Observed: no answer through the tunnel (\(failure.summary)). The SYN is not reaching LocalDevVPN, or is not being returned (case A or B).")
			}
		case nil:
			tunnelWorks = false
		}

		let restrictedRejected: Bool
		if case .accepted? = r.tunnelLoopback, case .failed(let failure)? = r.tunnelLoopbackNoCellular {
			restrictedRejected = true
			out.append("Observed: a listener that prohibits cellular is not reachable through the tunnel here (\(failure.summary)), while an unrestricted one is. iOS applies cellular restrictions to traffic arriving through the tunnel on this network.")
		} else {
			restrictedRejected = false
		}

		if case .failed(let failure)? = r.remotePairingViaTunnel, tunnelWorks, failure == .refused || failure == .reset {
			out.append("Inferred: the \(failure.summary.lowercased()) on the RemotePairing port was generated by this iPhone's own TCP stack after the reflected SYN arrived. No other host is on this path. No RemotePairing listener accepted connections arriving through the tunnel.")
			if restrictedRejected {
				out.append("Hypothesis (strongly consistent): the RemotePairing listener excludes cellular in the same way, so it rejects tunnel traffic whenever iOS treats the tunnel as cellular, and accepts it on Wi-Fi or with no network (Airplane Mode).")
			}
		}
		if case .accepted? = r.remotePairingViaTunnel {
			out.append("Observed: the RemotePairing port accepted a connection through the tunnel.")
		}

		switch (r.remotePairingDirect, r.remotePairingViaTunnel) {
		case (.accepted?, .failed?):
			out.append("Observed: the RemotePairing listener is running and accepts connections to the tunnel address directly, but not through the tunnel. Its rejection depends on the arrival interface, not on the service being stopped. The direct health check tests whether a full session works on this path.")
		case (.failed(let failure)?, .failed?):
			out.append("Observed: the RemotePairing port also \(failure == .refused ? "refused" : "failed") a direct connection to the tunnel address (\(failure.summary)).")
		default:
			break
		}
		if case .accepted? = r.remotePairingLoopback {
			out.append("Observed: the RemotePairing port accepts on 127.0.0.1, so the listener is bound to all addresses.")
		}

		switch (r.idleLoopback, r.idleViaTunnel) {
		case (let loopback?, .stillOpen?) where loopback.rejectsWithoutRequest:
			out.append("Observed: with nothing sent, the service \(describe(loopback)) on loopback, but kept the tunnel connection open and waited for a request. The loopback rejection does not depend on what Zag Store sends; it depends on how the connection arrives (source address or interface).")
		case (let loopback?, _) where loopback.rejectsWithoutRequest:
			out.append("Observed: with nothing sent, the service \(describe(loopback)) on loopback. The rejection does not depend on request content.")
		case (.stillOpen?, .stillOpen?):
			out.append("Observed: the service waits for a request on both loopback and the tunnel. A loopback rejection therefore happens after the request is read; see the health check's wire log.")
		case (.stillOpen?, _):
			out.append("Observed: the service keeps an idle loopback connection open and waits for a request.")
		default:
			break
		}
		return out
	}

	static func report(_ r: ZagTransportTraceResult, generatedAt: Date = Date(), deviceSummary: String = "") -> String {
		var lines = ["Zag Store connection trace"]
		lines.append("Generated: \(ISO8601DateFormatter().string(from: generatedAt))")
		if !deviceSummary.isEmpty { lines.append("Device: \(deviceSummary)") }
		lines.append("System networks: \(r.systemNetworks.isEmpty ? "none" : r.systemNetworks.joined(separator: ", "))\(r.systemPathExpensive == true ? " (expensive)" : "")")
		lines.append("Tunnel interfaces: \(r.tunnelInterfaces.isEmpty ? "none" : r.tunnelInterfaces.joined(separator: ", "))")
		lines.append("Route source for peer: \(r.routeSource ?? "none")")
		lines.append("Peer path: \(r.peerPathInterfaces.isEmpty ? "unavailable" : r.peerPathInterfaces.joined(separator: ", ")); cellular=\(flag(r.peerPathUsesCellular)) wifi=\(flag(r.peerPathUsesWiFi)) expensive=\(flag(r.peerPathExpensive))")
		lines.append("")
		lines.append("Timeline:")
		for step in r.steps { lines.append("  [\(step.milliseconds) ms] \(step.name): \(step.outcome)") }
		lines.append("")
		lines.append("Findings:")
		for finding in findings(r) { lines.append("- \(finding)") }
		return ZagDiagnosticReport.redact(lines.joined(separator: "\n"))
	}

	static func describe(_ outcome: ZagIdleOutcome?) -> String {
		guard let outcome else { return "not run" }
		switch outcome {
		case .stillOpen(let ms): return "kept open for \(ms) ms"
		case .closedByPeer(let ms): return "closed the connection after \(ms) ms"
		case .reset(let ms): return "reset the connection after \(ms) ms"
		case .dataReceived(let bytes, let ms): return "sent \(bytes) bytes first after \(ms) ms"
		case .notConnected(let failure): return "not connected (\(failure.summary))"
		}
	}

	static func describe(_ result: ZagEndpointProbeResult?) -> String {
		guard let result else { return "not run" }
		switch result {
		case .accepted(let ms): return "accepted in \(ms) ms"
		case .failed(let failure): return failure.summary
		}
	}

	private static func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }

	// MARK: Measurements

	/// Local source address the kernel selects for `host` (UDP connect sends
	/// nothing).
	static func routeSource(to host: String) -> String? {
		let fd = socket(AF_INET, SOCK_DGRAM, 0)
		guard fd >= 0 else { return nil }
		defer { close(fd) }
		var remote = sockaddr_in()
		remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		remote.sin_family = sa_family_t(AF_INET)
		remote.sin_port = UInt16(9).bigEndian
		guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
		let connected = withUnsafePointer(to: &remote) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		guard connected == 0 else { return "connect failed: errno \(errno)" }
		var local = sockaddr_in()
		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
		let named = withUnsafeMutablePointer(to: &local) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
		}
		guard named == 0 else { return nil }
		var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
		guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
		return String(cString: buffer)
	}

	private struct PathSnapshot {
		var interfaces: [String] = []
		var cellular: Bool?
		var wifi: Bool?
		var expensive: Bool?
	}

	/// Network.framework's view of a path to the peer, from a UDP connection
	/// that never sends a datagram.
	private static func peerPath(_ host: String) async -> PathSnapshot {
		let connection = NWConnection(host: NWEndpoint.Host(host), port: 9, using: .udp)
		let once = Once<PathSnapshot>()
		return await withCheckedContinuation { continuation in
			once.set { continuation.resume(returning: $0) }
			connection.stateUpdateHandler = { state in
				switch state {
				case .ready, .waiting:
					var snapshot = PathSnapshot()
					if let path = connection.currentPath {
						snapshot.interfaces = path.availableInterfaces.map { "\($0.name) (\(typeName($0.type)))" }
						snapshot.cellular = path.usesInterfaceType(.cellular)
						snapshot.wifi = path.usesInterfaceType(.wifi)
						snapshot.expensive = path.isExpensive
					}
					connection.cancel()
					once.fire(snapshot)
				case .failed, .cancelled:
					once.fire(PathSnapshot())
				default:
					break
				}
			}
			connection.start(queue: queue)
			queue.asyncAfter(deadline: .now() + 1.5) {
				connection.cancel()
				once.fire(PathSnapshot())
			}
		}
	}

	private static func systemPath() async -> (networks: [String], expensive: Bool) {
		let monitor = NWPathMonitor()
		let once = Once<(networks: [String], expensive: Bool)>()
		return await withCheckedContinuation { continuation in
			once.set { continuation.resume(returning: $0) }
			monitor.pathUpdateHandler = { path in
				let networks = path.availableInterfaces.compactMap { interface -> String? in
					switch interface.type {
					case .wifi: return "Wi-Fi"
					case .cellular: return "Cellular"
					case .wiredEthernet: return "Wired"
					default: return nil
					}
				}
				monitor.cancel()
				once.fire((networks, path.isExpensive))
			}
			monitor.start(queue: queue)
			queue.asyncAfter(deadline: .now() + 1.5) {
				monitor.cancel()
				once.fire(([], false))
			}
		}
	}

	/// Opens a short-lived listener on an ephemeral port and connects to it
	/// through the peer address. Through LocalDevVPN the connection only
	/// reaches the listener if TCP crosses the tunnel both ways.
	static func loopback(peer: String, prohibitCellular: Bool, timeout: TimeInterval) async -> ZagEndpointProbeResult {
		let parameters = NWParameters.tcp
		if prohibitCellular { parameters.prohibitedInterfaceTypes = [.cellular] }
		guard let listener = try? NWListener(using: parameters, on: .any) else {
			return .failed(.failed("Listener could not be created"))
		}
		listener.newConnectionHandler = { connection in
			connection.start(queue: queue)
			queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
		}
		let once = Once<UInt16?>()
		let port: UInt16? = await withCheckedContinuation { continuation in
			once.set { continuation.resume(returning: $0) }
			listener.stateUpdateHandler = { state in
				switch state {
				case .ready: once.fire(listener.port?.rawValue)
				case .failed, .cancelled: once.fire(nil)
				default: break
				}
			}
			listener.start(queue: queue)
			queue.asyncAfter(deadline: .now() + 2) { once.fire(nil) }
		}
		defer { listener.cancel() }
		guard let port else { return .failed(.failed("Listener did not start")) }
		return await ZagEndpointProbe.connect(host: peer, port: port, timeout: timeout)
	}

	/// Connects, sends nothing, and reports what the peer does within `wait`.
	/// The connection is always cancelled at the end.
	static func idle(host: String, port: UInt16, connectTimeout: TimeInterval, wait: TimeInterval) async -> ZagIdleOutcome {
		let connection = NWConnection(
			host: NWEndpoint.Host(host),
			port: NWEndpoint.Port(rawValue: port) ?? 49152,
			using: .tcp
		)
		let once = Once<ZagIdleOutcome>()
		let start = ProcessInfo.processInfo.systemUptime
		func elapsed() -> Int { Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
		func classify(_ error: NWError) -> ZagIdleOutcome {
			if case .posix(let code) = error {
				switch code {
				case .ECONNRESET, .ECONNABORTED, .EPIPE: return .reset(milliseconds: elapsed())
				case .ECONNREFUSED: return .notConnected(.refused)
				default: break
				}
			}
			return .notConnected(.failed(error.debugDescription))
		}
		let outcome: ZagIdleOutcome = await withCheckedContinuation { continuation in
			once.set { continuation.resume(returning: $0) }
			let connected = Flag()
			connection.stateUpdateHandler = { state in
				switch state {
				case .ready:
					connected.set()
					queue.asyncAfter(deadline: .now() + wait) { once.fire(.stillOpen(waitedMilliseconds: elapsed())) }
					connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
						if let data, !data.isEmpty {
							once.fire(.dataReceived(bytes: data.count, milliseconds: elapsed()))
						} else if let error {
							once.fire(classify(error))
						} else if isComplete {
							once.fire(.closedByPeer(milliseconds: elapsed()))
						}
					}
				case .waiting(let error):
					if case .posix(.ECONNREFUSED) = error { once.fire(.notConnected(.refused)) }
				case .failed(let error):
					once.fire(connected.value ? classify(error) : .notConnected(.failed(error.debugDescription)))
				default:
					break
				}
			}
			connection.start(queue: queue)
			queue.asyncAfter(deadline: .now() + connectTimeout) {
				if !connected.value { once.fire(.notConnected(.timedOut)) }
			}
		}
		connection.stateUpdateHandler = nil
		connection.cancel()
		return outcome
	}

	private static func typeName(_ type: NWInterface.InterfaceType) -> String {
		switch type {
		case .wifi: return "Wi-Fi"
		case .cellular: return "cellular"
		case .wiredEthernet: return "wired"
		case .loopback: return "loopback"
		case .other: return "other"
		@unknown default: return "unknown"
		}
	}

	private static let queue = DispatchQueue(label: "app.zagstore.transport-trace")

	/// A thread-safe one-way flag.
	private final class Flag: @unchecked Sendable {
		private let lock = NSLock()
		private var isSet = false
		func set() { lock.lock(); isSet = true; lock.unlock() }
		var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
	}

	/// Delivers a value to one continuation exactly once.
	private final class Once<Value>: @unchecked Sendable {
		private let lock = NSLock()
		private var handler: ((Value) -> Void)?
		func set(_ handler: @escaping (Value) -> Void) {
			lock.lock(); self.handler = handler; lock.unlock()
		}
		func fire(_ value: Value) {
			lock.lock()
			let handler = self.handler
			self.handler = nil
			lock.unlock()
			handler?(value)
		}
	}
}

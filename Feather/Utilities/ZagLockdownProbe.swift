import Foundation
import Network

/// Connect-only check of the RemotePairing endpoint that every RPPairing
/// session opens first. It sends nothing and closes as soon as the
/// connection is accepted, so it never starts a pairing handshake.
enum ZagEndpointProbe {
	static func connect(
		host: String = ZagDeviceLink.peerAddress,
		port: UInt16 = ZagDeviceLink.rsdPort,
		timeout: TimeInterval = 3
	) async -> ZagEndpointProbeResult {
		switch await ZagLockdownProbe.run(host: host, port: port, timeout: timeout, sendQuery: false) {
		case .lockdownReachable(let milliseconds): return .accepted(milliseconds: milliseconds)
		case .failed(let failure): return .failed(failure)
		}
	}
}

/// One short lockdown `QueryType` exchange on the legacy lockdown port.
/// Diagnostic evidence only: the RPPairing transport does not use this port.
///
/// Both probes use default TCP parameters, so they are never tied to Wi-Fi
/// or cellular: the system routes the peer address into the LocalDevVPN
/// tunnel on any network. The connection is always cancelled when the probe
/// ends, whatever the outcome.
enum ZagLockdownProbe {
	static func query(
		host: String = ZagDeviceLink.peerAddress,
		port: UInt16 = ZagDeviceLink.lockdownPort,
		timeout: TimeInterval = 3
	) async -> ZagDeviceProbeResult {
		await run(host: host, port: port, timeout: timeout, sendQuery: true)
	}

	static func run(host: String, port: UInt16, timeout: TimeInterval, sendQuery: Bool) async -> ZagDeviceProbeResult {
		let attempt = Attempt(host: host, port: port, timeout: timeout, sendQuery: sendQuery)
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				attempt.start { continuation.resume(returning: $0) }
			}
		} onCancel: {
			attempt.finish(.failed(.failed("Cancelled")))
		}
	}

	/// Owns one NWConnection. Every path (reply, error, timeout, cancellation)
	/// funnels into `finish`, which delivers exactly one result.
	private final class Attempt: @unchecked Sendable {
		private let connection: NWConnection
		private let queue = DispatchQueue(label: "app.zagstore.lockdown-probe")
		private let timeout: TimeInterval
		private let sendsQuery: Bool
		private let lock = NSLock()
		private var completion: ((ZagDeviceProbeResult) -> Void)?
		private var finished = false
		private var received = Data()
		private var waitingReason: String?
		private let startedAt = ProcessInfo.processInfo.systemUptime

		init(host: String, port: UInt16, timeout: TimeInterval, sendQuery: Bool) {
			sendsQuery = sendQuery
			connection = NWConnection(
				host: NWEndpoint.Host(host),
				port: NWEndpoint.Port(rawValue: port) ?? 62078,
				using: .tcp
			)
			self.timeout = timeout
		}

		func start(_ completion: @escaping (ZagDeviceProbeResult) -> Void) {
			lock.lock()
			if finished {
				lock.unlock()
				completion(.failed(.failed("Cancelled")))
				return
			}
			self.completion = completion
			lock.unlock()

			connection.stateUpdateHandler = { [weak self] state in
				guard let self else { return }
				switch state {
				case .ready:
					if self.sendsQuery {
						self.sendQuery()
					} else {
						self.finish(.lockdownReachable(milliseconds: self.elapsedMilliseconds))
					}
				case .waiting(let error):
					// Network.framework reports a refused connection as
					// `.waiting`; that is a definite answer, so finish now.
					let failure = Self.failure(for: error)
					if failure == .refused || failure == .reset {
						self.finish(.failed(failure))
						return
					}
					// Otherwise keep waiting until the timeout, but remember why.
					self.lock.lock()
					self.waitingReason = error.debugDescription
					self.lock.unlock()
				case .failed(let error):
					self.finish(.failed(Self.failure(for: error)))
				default:
					break
				}
			}
			connection.start(queue: queue)
			queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
				guard let self else { return }
				self.lock.lock()
				let reason = self.waitingReason
				self.lock.unlock()
				self.finish(.failed(reason.map { .waiting($0) } ?? .timedOut))
			}
		}

		private func sendQuery() {
			connection.send(content: ZagLockdownQuery.request(), completion: .contentProcessed { [weak self] error in
				guard let self else { return }
				if let error {
					self.finish(.failed(Self.failure(for: error)))
				} else {
					self.receive()
				}
			})
		}

		private func receive() {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
				guard let self else { return }
				if let data { self.received.append(data) }
				switch ZagLockdownQuery.parse(self.received) {
				case .lockdown:
					self.finish(.lockdownReachable(milliseconds: self.elapsedMilliseconds))
				case .invalid(let reason):
					self.finish(.failed(.invalidResponse(reason)))
				case .needMoreData:
					if let error {
						self.finish(.failed(Self.failure(for: error)))
					} else if isComplete {
						// Accepted, then closed without a full reply.
						self.finish(.failed(self.received.isEmpty ? .reset : .invalidResponse("Reply ended early")))
					} else {
						self.receive()
					}
				}
			}
		}

		private var elapsedMilliseconds: Int {
			Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
		}

		func finish(_ result: ZagDeviceProbeResult) {
			lock.lock()
			guard !finished else { lock.unlock(); return }
			finished = true
			let completion = self.completion
			self.completion = nil
			lock.unlock()
			connection.stateUpdateHandler = nil
			connection.cancel()
			completion?(result)
		}

		static func failure(for error: NWError) -> ZagDeviceProbeFailure {
			if case .posix(let code) = error {
				switch code {
				case .ECONNREFUSED: return .refused
				case .ECONNRESET, .ECONNABORTED, .EPIPE: return .reset
				case .ETIMEDOUT: return .timedOut
				default: break
				}
			}
			return .failed(error.debugDescription)
		}
	}
}

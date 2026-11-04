import Foundation
import Network

// Compiled with Feather/Utilities/ZagDeviceLink.swift and
// Feather/Utilities/ZagLockdownProbe.swift by scripts/test-zag-device-link.sh.
// The probe tests run the real NWConnection code against a fake lockdown
// server on 127.0.0.1, so framing, timeouts and cleanup are exercised for real.

@main struct ZagDeviceLinkTests {
	nonisolated(unsafe) static var failures = 0

	static func expect(_ condition: Bool, _ label: String) {
		print((condition ? "PASS  " : "FAIL  ") + label)
		if !condition { failures += 1 }
	}

	// MARK: Fake lockdown server

	enum ServerMode {
		case lockdown(split: Bool, binary: Bool)
		case wrongType
		case garbageLength
		case acceptThenClose
		case silent
	}

	final class FakeServer: @unchecked Sendable {
		let listener: NWListener
		let queue = DispatchQueue(label: "fake-lockdown")
		let mode: ServerMode
		private let lock = NSLock()
		private var _connections = 0
		private var _requests: [Data] = []
		var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }
		var requests: [Data] { lock.lock(); defer { lock.unlock() }; return _requests }

		init(mode: ServerMode) throws {
			self.mode = mode
			let parameters = NWParameters.tcp
			parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
			listener = try NWListener(using: parameters)
		}

		func start() async -> UInt16 {
			listener.newConnectionHandler = { [weak self] connection in
				guard let self else { return }
				self.lock.lock(); self._connections += 1; self.lock.unlock()
				connection.start(queue: self.queue)
				self.serve(connection)
			}
			return await withCheckedContinuation { continuation in
				listener.stateUpdateHandler = { [weak self] state in
					if case .ready = state, let self, let port = self.listener.port?.rawValue {
						self.listener.stateUpdateHandler = nil
						continuation.resume(returning: port)
					}
				}
				listener.start(queue: queue)
			}
		}

		func stop() { listener.cancel() }

		private func serve(_ connection: NWConnection) {
			if case .acceptThenClose = mode {
				queue.asyncAfter(deadline: .now() + 0.05) { connection.cancel() }
				return
			}
			connection.receive(minimumIncompleteLength: 4, maximumLength: 4096) { [weak self] data, _, _, _ in
				guard let self, let data else { return }
				self.lock.lock(); self._requests.append(data); self.lock.unlock()
				switch self.mode {
				case .lockdown(let split, let binary):
					let reply = FakeServer.frame(["Request": "QueryType", "Type": "com.apple.mobile.lockdown"], binary: binary)
					if split {
						connection.send(content: reply.prefix(6), completion: .contentProcessed { _ in
							self.queue.asyncAfter(deadline: .now() + 0.05) {
								connection.send(content: reply.dropFirst(6), completion: .idempotent)
							}
						})
					} else {
						connection.send(content: reply, completion: .idempotent)
					}
				case .wrongType:
					connection.send(content: FakeServer.frame(["Type": "com.apple.mobile.restored"], binary: false), completion: .idempotent)
				case .garbageLength:
					connection.send(content: Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00]), completion: .idempotent)
				case .silent, .acceptThenClose:
					break
				}
			}
		}

		static func frame(_ dictionary: [String: String], binary: Bool) -> Data {
			let body = try! PropertyListSerialization.data(fromPropertyList: dictionary, format: binary ? .binary : .xml, options: 0)
			var length = UInt32(body.count).bigEndian
			var data = Data(bytes: &length, count: 4)
			data.append(body)
			return data
		}
	}

	static func closedPort() async throws -> UInt16 {
		let server = try FakeServer(mode: .silent)
		let port = await server.start()
		server.stop()
		try await Task.sleep(nanoseconds: 100_000_000)
		return port
	}

	// MARK: Probe tests

	static func probeTests() async throws {
		for (split, binary, name) in [(false, false, "XML"), (true, false, "split XML"), (false, true, "binary")] {
			let server = try FakeServer(mode: .lockdown(split: split, binary: binary))
			let port = await server.start()
			let result = await ZagLockdownProbe.query(host: "127.0.0.1", port: port, timeout: 2)
			if case .lockdownReachable = result { expect(true, "probe: valid \(name) QueryType reply is reachable") }
			else { expect(false, "probe: valid \(name) QueryType reply is reachable (got \(result))") }
			server.stop()
		}

		// The request must be a correctly framed QueryType.
		let framed = try FakeServer(mode: .lockdown(split: false, binary: false))
		let framedPort = await framed.start()
		_ = await ZagLockdownProbe.query(host: "127.0.0.1", port: framedPort, timeout: 2)
		let sent = framed.requests.first ?? Data()
		let declared = sent.count >= 4 ? Int(sent[0]) << 24 | Int(sent[1]) << 16 | Int(sent[2]) << 8 | Int(sent[3]) : -1
		let body = sent.count > 4 ? sent.subdata(in: 4..<sent.count) : Data()
		let plist = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: String]
		expect(declared == body.count && plist?["Request"] == "QueryType", "probe: request is length-prefixed XML QueryType")
		framed.stop()

		// TCP accepted, then a protocol failure: never reachable.
		for (mode, label) in [(ServerMode.wrongType, "wrong service type"), (.garbageLength, "garbage length")] {
			let server = try FakeServer(mode: mode)
			let port = await server.start()
			let result = await ZagLockdownProbe.query(host: "127.0.0.1", port: port, timeout: 2)
			if case .failed(.invalidResponse) = result { expect(true, "probe: TCP success with \(label) is a protocol failure") }
			else { expect(false, "probe: TCP success with \(label) is a protocol failure (got \(result))") }
			server.stop()
		}

		let closing = try FakeServer(mode: .acceptThenClose)
		let closingPort = await closing.start()
		let closed = await ZagLockdownProbe.query(host: "127.0.0.1", port: closingPort, timeout: 2)
		expect(closed == .failed(.reset) || closed == .failed(.invalidResponse("Reply ended early")),
			"probe: accepted then closed is not reachable (got \(closed))")
		closing.stop()

		let refusedPort = try await closedPort()
		let refused = await ZagLockdownProbe.query(host: "127.0.0.1", port: refusedPort, timeout: 2)
		expect(refused == .failed(.refused), "probe: no listener is reported as refused (got \(refused))")

		let silent = try FakeServer(mode: .silent)
		let silentPort = await silent.start()
		let started = Date()
		let timedOut = await ZagLockdownProbe.query(host: "127.0.0.1", port: silentPort, timeout: 0.5)
		let elapsed = Date().timeIntervalSince(started)
		expect(timedOut == .failed(.timedOut), "probe: a silent service times out (got \(timedOut))")
		expect(elapsed < 1.5, "probe: the timeout is honoured (\(String(format: "%.2f", elapsed)) s)")
		silent.stop()

		// Cancellation ends the probe promptly and closes the connection.
		let hanging = try FakeServer(mode: .silent)
		let hangingPort = await hanging.start()
		let cancelStart = Date()
		let task = Task { await ZagLockdownProbe.query(host: "127.0.0.1", port: hangingPort, timeout: 5) }
		try await Task.sleep(nanoseconds: 200_000_000)
		task.cancel()
		let cancelled = await task.value
		expect(Date().timeIntervalSince(cancelStart) < 1.5 && cancelled == .failed(.failed("Cancelled")),
			"probe: cancellation ends the probe promptly (got \(cancelled))")
		hanging.stop()

		// Each probe opens exactly one connection: no hidden retries.
		let counting = try FakeServer(mode: .lockdown(split: false, binary: false))
		let countingPort = await counting.start()
		for _ in 0..<3 { _ = await ZagLockdownProbe.query(host: "127.0.0.1", port: countingPort, timeout: 2) }
		try await Task.sleep(nanoseconds: 100_000_000)
		expect(counting.connections == 3, "probe: one connection per probe (got \(counting.connections) for 3)")
		counting.stop()
	}

	// MARK: Pure logic tests

	static func parserTests() {
		expect(ZagLockdownQuery.parse(Data([0, 0])) == .needMoreData, "parser: a partial length waits for more")
		let reply = FakeServer.frame(["Type": "com.apple.mobile.lockdown"], binary: false)
		expect(ZagLockdownQuery.parse(reply.prefix(10)) == .needMoreData, "parser: a partial body waits for more")
		expect(ZagLockdownQuery.parse(reply) == .lockdown, "parser: a full reply is lockdown")
		expect(ZagLockdownQuery.parse(FakeServer.frame(["Error": "InvalidService"], binary: false)) == .invalid("lockdownd error: InvalidService"),
			"parser: a lockdown error is reported")
		expect(ZagLockdownQuery.parse(Data([0, 0, 0, 0])) == .invalid("Unexpected reply length 0"), "parser: zero length is invalid")
	}

	static func schedulerTests() {
		var scheduler = ZagDeviceProbeScheduler()
		let first = scheduler.request()
		expect(first == 1, "scheduler: the first request starts a probe")
		// Several rapid path changes while probing.
		expect(scheduler.request() == nil && scheduler.request() == nil && scheduler.request() == nil,
			"scheduler: requests during a probe do not start overlapping probes")
		expect(scheduler.recheckPending, "scheduler: a request during a probe is remembered")
		let finished = scheduler.finish(first!)
		expect(finished.accepted && finished.next == 2, "scheduler: the remembered re-check starts as soon as the probe ends")
		let second = scheduler.finish(2)
		expect(second.accepted && second.next == nil && scheduler.running == nil, "scheduler: rapid changes collapse into one re-check")

		var stale = ZagDeviceProbeScheduler()
		let old = stale.request()!
		stale.cancel()
		expect(!stale.finish(old).accepted, "scheduler: a cancelled probe's result is ignored")
		let fresh = stale.request()
		expect(fresh != nil && fresh != old, "scheduler: a new probe can start after cancellation")
		expect(!stale.finish(old).accepted && stale.running == fresh, "scheduler: a late stale result does not end the current probe")
	}

	static func statusTests() {
		typealias T = ZagDeviceLinkTransitions
		expect(T.status(tunnelPresent: true, probe: .lockdownReachable(milliseconds: 4)) == .reachable(milliseconds: 4),
			"status: a lockdown reply is reachable")
		expect(T.status(tunnelPresent: false, probe: .lockdownReachable(milliseconds: 4)).isReachable,
			"status: a lockdown reply wins even if the tunnel interface was not recognised")
		expect(T.status(tunnelPresent: false, probe: .failed(.timedOut)) == .tunnelUnavailable,
			"status: no tunnel interface and no reply means LocalDevVPN is off")
		expect(T.status(tunnelPresent: true, probe: .failed(.refused)) == .serviceUnreachable(.refused),
			"status: tunnel present but refused is a device-service failure, not VPN off")
		expect(T.status(tunnelPresent: true, probe: .failed(.invalidResponse("x"))) == .serviceUnreachable(.invalidResponse("x")),
			"status: TCP success with a bad reply is never reachable")
		expect(T.statusWhileChecking(.reachable(milliseconds: 3)) == .reachable(milliseconds: 3),
			"status: a re-check while ON keeps ON (no flicker)")
		expect(T.statusWhileChecking(.tunnelUnavailable) == .checking, "status: a re-check while not ON shows checking")
		expect(T.pollInterval(for: .reachable(milliseconds: 3)) == 60 && T.pollInterval(for: .tunnelUnavailable) == 12,
			"status: polling relaxes to 60 s once reachable")

		// VPN disconnect, then reconnect.
		var status = T.status(tunnelPresent: true, probe: .lockdownReachable(milliseconds: 5))
		status = T.status(tunnelPresent: false, probe: .failed(.timedOut))
		expect(status == .tunnelUnavailable, "status: VPN disconnect turns ON into tunnel unavailable")
		status = T.statusWhileChecking(status)
		status = T.status(tunnelPresent: true, probe: .lockdownReachable(milliseconds: 6))
		expect(status == .reachable(milliseconds: 6), "status: VPN reconnect returns to reachable")

		expect(ZagTunnelInterface.isLocalDevTunnel(name: "utun4", ipv4: "10.7.1.1"), "tunnel: LocalDevVPN default address is recognised")
		expect(ZagTunnelInterface.isLocalDevTunnel(name: "utun2", ipv4: "10.7.0.0"), "tunnel: StosVPN address is recognised")
		expect(!ZagTunnelInterface.isLocalDevTunnel(name: "en0", ipv4: "10.7.1.1"), "tunnel: a physical interface is not the tunnel")
		expect(!ZagTunnelInterface.isLocalDevTunnel(name: "utun3", ipv4: "10.8.0.2"), "tunnel: another VPN's address is not LocalDevVPN")
		expect(!ZagTunnelInterface.containsLocalDevTunnel([("pdp_ip0", "100.64.3.2"), ("en0", "192.168.1.4")]),
			"tunnel: cellular and Wi-Fi alone are not the tunnel")
	}

	static func classificationTests() {
		typealias F = ZagRPPairingFailure
		let cases: [(String, ZagRPPairingFailureKind)] = [
			("Unable to read saved RPPairing credentials: No such file", .pairingFile),
			("Timed out reaching RPPairing at 10.7.0.1:49152", .deviceUnreachable),
			("Unable to reach RPPairing at 10.7.0.1:49152: Connection refused (os error 61)", .deviceUnreachable),
			("RPPairing pair-verify failed: socket io failed: Connection reset by peer", .connectionInterrupted),
			("RPPairing pair-verify failed: invalid signature", .pairingRejected),
			("TLS-PSK CDTunnel failed: handshake error", .sessionSetup),
			("RSD handshake failed: unexpected eof", .connectionInterrupted),
			("Zag Store self-update refused: installed app not found; fresh installation is forbidden", .other),
		]
		for (message, kind) in cases {
			let got = F.classify(message, installationStarted: false)
			expect(got == kind, "classify: \"\(message.prefix(48))\" is \(kind) (got \(got))")
		}
		expect(F.classify("Timed out reaching RPPairing at 10.7.0.1:49152", installationStarted: true) == .installation,
			"classify: anything after installation began is an installation failure")
		expect(!F.isRetryable(.installation) && !F.isRetryable(.pairingRejected) && !F.isRetryable(.pairingFile) && !F.isRetryable(.other),
			"classify: installation, credential and unknown failures are never retried")
		expect(F.isRetryable(.deviceUnreachable) && F.isRetryable(.connectionInterrupted) && F.isRetryable(.sessionSetup),
			"classify: pre-install transport failures are retryable")
		// Pairing records are preserved: no network failure suggests re-pairing.
		for kind in [ZagRPPairingFailureKind.deviceUnreachable, .connectionInterrupted, .sessionSetup, .installation, .other] {
			expect(!F.suggestsRepairing(kind), "pairing record: \(kind) never suggests re-pairing")
		}
		expect(F.suggestsRepairing(.pairingRejected), "pairing record: a rejected pairing suggests re-pairing (user decides)")
		expect(!F.explanation(.deviceUnreachable).lowercased().contains("cellular"), "messages: no unproven cellular claim")
	}

	static func retryTests() {
		var plan = ZagGate4RetryPlan()
		expect(plan.begin(), "retry: an install can begin")
		expect(!plan.begin(), "retry: a second install cannot begin while one is active (no duplicates)")
		expect(plan.delayAfterFailure(.deviceUnreachable) == 1, "retry: first transient failure retries after 1 s")
		expect(plan.delayAfterFailure(.connectionInterrupted) == 3, "retry: second transient failure retries after 3 s")
		expect(plan.delayAfterFailure(.sessionSetup) == nil && !plan.active, "retry: retries are exhausted after two, and the plan ends")
		expect(plan.begin() && plan.retriesUsed == 0, "retry: a new install starts with a fresh budget")
		expect(plan.delayAfterFailure(.installation) == nil && !plan.active, "retry: a failure after installation began is never retried")
		_ = plan.begin()
		plan.end()
		expect(plan.delayAfterFailure(.deviceUnreachable) == nil, "retry: nothing is retried after the install ended")
	}

	static func main() async {
		parserTests()
		schedulerTests()
		statusTests()
		classificationTests()
		retryTests()
		do { try await probeTests() } catch { expect(false, "probe tests threw \(error)") }
		if failures > 0 {
			print("\(failures) device link test(s) failed")
			exit(1)
		}
		print("All device link tests passed")
	}
}

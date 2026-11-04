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

		// The RemotePairing endpoint check is connect-only. Against a server
		// that resets anything that sends a lockdown request (the behaviour
		// seen on iOS 27 over Wi-Fi), it still reports the endpoint accepted.
		let endpoint = try FakeServer(mode: .silent)
		let endpointPort = await endpoint.start()
		let accepted = await ZagEndpointProbe.connect(host: "127.0.0.1", port: endpointPort, timeout: 2)
		try await Task.sleep(nanoseconds: 150_000_000)
		if case .accepted = accepted { expect(true, "endpoint: an accepting endpoint is reachable") }
		else { expect(false, "endpoint: an accepting endpoint is reachable (got \(accepted))") }
		expect(endpoint.requests.isEmpty, "endpoint: the check sends no bytes (no handshake started)")
		endpoint.stop()

		let resetting = try FakeServer(mode: .acceptThenClose)
		let resettingPort = await resetting.start()
		let legacy = await ZagLockdownProbe.query(host: "127.0.0.1", port: resettingPort, timeout: 2)
		let sameEndpoint = await ZagEndpointProbe.connect(host: "127.0.0.1", port: resettingPort, timeout: 2)
		if case .accepted = sameEndpoint, case .failed = legacy {
			expect(true, "endpoint: a failed legacy QueryType does not make an accepting endpoint unreachable")
		} else {
			expect(false, "endpoint: legacy failure independent of endpoint (legacy \(legacy), endpoint \(sameEndpoint))")
		}
		resetting.stop()

		let closedEndpoint = try await closedPort()
		let refusedEndpoint = await ZagEndpointProbe.connect(host: "127.0.0.1", port: closedEndpoint, timeout: 2)
		expect(refusedEndpoint == .failed(.refused) && refusedEndpoint.deviceAnswered,
			"endpoint: a refused endpoint is classified as refused, with the device answering")

		let hangingEndpoint = Task { await ZagEndpointProbe.connect(host: "192.0.2.1", port: 49152, timeout: 0.6) }
		let unreachable = await hangingEndpoint.value
		expect(!unreachable.deviceAnswered, "endpoint: an unroutable address is never counted as an answer (got \(unreachable))")
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

	static func modelTests() {
		let t0 = Date(timeIntervalSince1970: 1_000_000)
		func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

		// 1. A successful real RPPairing diagnostic is represented correctly.
		var m = ZagDeviceLinkModel()
		expect(m.indicator == .off && m.pairing == .notChecked && m.service == .notChecked,
			"model: nothing checked shows not checked, not success or failure")
		m.pairingEvent(.verified(at(1)))
		expect(m.pairing == .verified(at(1)) && m.tunnel == .operational && m.indicator == .on,
			"model: a verified health check is ON with RPPairing verified")

		// 2. The optional legacy lockdown probe cannot affect status at all:
		// the model has no input for it. The endpoint probe failing *before*
		// a newer verification cannot overwrite it.
		var raced = ZagDeviceLinkModel()
		raced.probeStarted()
		raced.pairingEvent(.verified(at(5)))
		raced.probeFinished(.failed(.reset), interfacePresent: true, startedAt: at(4), finishedAt: at(6))
		expect(raced.pairing == .verified(at(5)) && raced.indicator == .on,
			"model: a probe that started before a real verification cannot overwrite it")

		// A genuinely newer refusal is a real new failure.
		var newer = m
		newer.probeFinished(.failed(.refused), interfacePresent: true, startedAt: at(10), finishedAt: at(11))
		expect(newer.indicator == .warning && newer.service == .unreachable(.refused, at(11)),
			"model: a refusal after the verification is reported, not masked")

		// 3. A genuine VPN disconnection invalidates stale readiness.
		var dropped = m
		dropped.probeFinished(.failed(.timedOut), interfacePresent: false, startedAt: at(20), finishedAt: at(23))
		expect(dropped.tunnel == .disconnected && dropped.pairing == .awaitingRevalidation(lastSuccess: at(1)) && dropped.indicator == .off,
			"model: VPN disconnect turns a verified session into awaiting revalidation")
		dropped.probeFinished(.accepted(milliseconds: 4), interfacePresent: true, startedAt: at(30), finishedAt: at(30))
		expect(dropped.indicator == .on && dropped.pairing == .awaitingRevalidation(lastSuccess: at(1)),
			"model: VPN reconnect is ON again, but RPPairing still needs revalidation")

		// A network change (Wi-Fi to cellular) also invalidates readiness.
		var moved = ZagDeviceLinkModel()
		moved.networkChanged(to: "Wi-Fi")
		moved.pairingEvent(.verified(at(1)))
		moved.networkChanged(to: "Wi-Fi")
		expect(moved.pairing == .verified(at(1)), "model: the same network does not invalidate readiness")
		moved.networkChanged(to: "Cellular")
		expect(moved.pairing == .awaitingRevalidation(lastSuccess: at(1)), "model: Wi-Fi to cellular invalidates readiness")
		var expiring = ZagDeviceLinkModel()
		expiring.pairingEvent(.verified(at(0)))
		expiring.expire(now: at(ZagDeviceLinkModel.pairingFreshness - 1))
		expect(expiring.pairing == .verified(at(0)), "model: a recent verification is still trusted")
		expiring.expire(now: at(ZagDeviceLinkModel.pairingFreshness + 1))
		expect(expiring.pairing == .awaitingRevalidation(lastSuccess: at(0)), "model: verification expires after 10 minutes")

		// 4. Rapid Wi-Fi/cellular transitions do not leave a stuck state.
		var flapping = ZagDeviceLinkModel()
		for (index, network) in ["Wi-Fi", "Cellular", "Wi-Fi", "Cellular", "Cellular"].enumerated() {
			flapping.networkChanged(to: network)
			flapping.probeStarted()
			flapping.probeFinished(.accepted(milliseconds: 3), interfacePresent: true, startedAt: at(Double(index)), finishedAt: at(Double(index) + 0.1))
		}
		expect(!flapping.checking && flapping.indicator == .on, "model: rapid transitions end in a settled state")
		var abandoned = ZagDeviceLinkModel()
		abandoned.probeStarted()
		expect(abandoned.indicator == .checking, "model: a first check shows checking")
		abandoned.probeAbandoned()
		expect(!abandoned.checking && abandoned.indicator == .off, "model: an abandoned probe never stays checking (backgrounding)")

		// 5. Older results cannot overwrite newer ones.
		var ordered = ZagDeviceLinkModel()
		ordered.pairingEvent(.verified(at(10)))
		ordered.pairingEvent(.failed(.pairingRejected, at(5)))
		expect(ordered.pairing == .verified(at(10)), "model: an older failure cannot overwrite a newer verification")
		ordered.pairingEvent(.failed(.pairingRejected, at(12)))
		expect(ordered.pairing == .failed(.pairingRejected, at(12)) && ordered.indicator == .warning,
			"model: a newer real failure replaces the verification and shows !")
		ordered.probeFinished(.accepted(milliseconds: 3), interfacePresent: true, startedAt: at(13), finishedAt: at(14))
		expect(ordered.indicator == .on, "model: a later reachable endpoint supersedes an older session failure")

		// 6 and 7. Refused or reset (the iPhone answered) differ from no answer.
		var answered = ZagDeviceLinkModel()
		answered.probeFinished(.failed(.reset), interfacePresent: true, startedAt: at(0), finishedAt: at(1))
		expect(answered.tunnel == .operational && answered.service == .unreachable(.reset, at(1)) && answered.indicator == .warning,
			"model: a reset means the tunnel works and the service rejected the connection")
		var silent = ZagDeviceLinkModel()
		silent.probeFinished(.failed(.timedOut), interfacePresent: true, startedAt: at(0), finishedAt: at(3))
		expect(silent.tunnel == .interfaceDetected && silent.indicator == .off,
			"model: a timeout with an interface is not reported as a confirmed failure")
		expect(!ZagDeviceLinkModel.tunnelIsDown(.failed(.refused), interfacePresent: false),
			"retry: a refusal proves the tunnel carried the packet")
		expect(ZagDeviceLinkModel.tunnelIsDown(.failed(.timedOut), interfacePresent: false),
			"retry: no answer and no interface means the tunnel is down")
		expect(!ZagDeviceLinkModel.tunnelIsDown(.failed(.timedOut), interfacePresent: true),
			"retry: a timeout with the interface present still allows a retry")

		var calm = ZagDeviceLinkModel()
		calm.probeFinished(.accepted(milliseconds: 3), interfacePresent: true, startedAt: at(0), finishedAt: at(0))
		expect(calm.pollInterval == 60 && silent.pollInterval == 12, "model: polling relaxes to 60 s once ON")

		expect(ZagTunnelInterface.isLocalDevTunnel(name: "utun4", ipv4: "10.7.1.1"), "tunnel: LocalDevVPN default address is recognised")
		expect(!ZagTunnelInterface.isLocalDevTunnel(name: "en0", ipv4: "10.7.1.1"), "tunnel: a physical interface is not the tunnel")
		expect(!ZagTunnelInterface.isLocalDevTunnel(name: "utun3", ipv4: "10.8.0.2"), "tunnel: another VPN's address is not LocalDevVPN")
	}

	static func reportTests() {
		var model = ZagDeviceLinkModel()
		model.networkChanged(to: "Cellular")
		let report = ZagDiagnosticReport.make(.init(
			generatedAt: Date(timeIntervalSince1970: 0), iOSVersion: "27.2", deviceModel: "iPhone",
			physicalNetworks: ["Cellular"], tunnelInterfaces: ["utun5"], model: model,
			endpointProbe: .failed(.refused), legacyLockdownProbe: .failed(.reset),
			steps: [
				ZagDiagnosticStep(stage: "RemotePairing endpoint", detail: "reachable", elapsedMilliseconds: 12, failed: false),
				ZagDiagnosticStep(stage: "After RemotePairing endpoint", detail: "pair-verify failed for 00008130-0001A2B3C4D5E6F7 peer 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b owner someone@example.com", elapsedMilliseconds: 40, failed: true),
			],
			sessionFailure: "RPPairing pair-verify failed: socket io failed"
		))
		expect(report.contains("Physical network: Cellular") && report.contains("10.7.0.1:49152"), "report: includes network type and target endpoint")
		expect(report.contains("First failing operation: Pair-Verify (verifyManualPairing)") && report.contains("Failure category: connectionInterrupted"),
			"report: names the first failing operation and its category")
		expect(report.contains("informational, not used by RPPairing"), "report: legacy lockdown is labelled as informational")
		expect(!report.contains("00008130-0001A2B3C4D5E6F7") && !report.contains("1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b") && !report.contains("someone@example.com"),
			"report: UDIDs, hex identifiers and emails are redacted")
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

	static func traceTests() async throws {
		// Real measurements on loopback: the "peer" is 127.0.0.1, so our own
		// listeners are reachable, and a closed port stands in for a
		// RemotePairing listener that rejects the connection.
		let closed = try await closedPort()
		let live = await ZagTransportTrace.run(peer: "127.0.0.1", servicePort: closed, tunnelAddress: "127.0.0.1", timeout: 1)
		expect(live.routeSource == "127.0.0.1", "trace: route source is measured (got \(live.routeSource ?? "nil"))")
		if case .accepted? = live.tunnelLoopback { expect(true, "trace: own listener reachable through the peer address") }
		else { expect(false, "trace: own listener reachable (got \(String(describing: live.tunnelLoopback)))") }
		if case .accepted? = live.tunnelLoopbackNoCellular { expect(true, "trace: a no-cellular listener is reachable off cellular") }
		else { expect(false, "trace: no-cellular listener off cellular (got \(String(describing: live.tunnelLoopbackNoCellular)))") }
		expect(live.remotePairingViaTunnel == .failed(.refused), "trace: a closed service port is refused")
		expect(live.steps.count == 11, "trace: every stage is timestamped (got \(live.steps.count))")
		if case .notConnected(.refused)? = live.idleLoopback { expect(true, "idle: a closed port is reported as not connected") }
		else { expect(false, "idle: closed port (got \(String(describing: live.idleLoopback)))") }
		let liveFindings = ZagTransportTrace.findings(live)
		expect(liveFindings.contains { $0.contains("own TCP stack") }, "trace: refusal with a working tunnel is attributed to the local stack")
		expect(!liveFindings.contains { $0.contains("Hypothesis") }, "trace: no cellular hypothesis without cellular evidence")

		// The cellular pattern this trace is designed to confirm or rule out.
		var cellular = ZagTransportTraceResult()
		cellular.tunnelInterfaces = ["utun5 10.7.1.1"]
		cellular.peerPathUsesCellular = true
		cellular.tunnelLoopback = .accepted(milliseconds: 4)
		cellular.tunnelLoopbackNoCellular = .failed(.refused)
		cellular.remotePairingViaTunnel = .failed(.refused)
		cellular.remotePairingDirect = .accepted(milliseconds: 2)
		let cf = ZagTransportTrace.findings(cellular)
		expect(cf.contains { $0.contains("cases A and B ruled out") }, "trace: a working tunnel loopback rules out cases A and B")
		expect(cf.contains { $0.hasPrefix("Hypothesis") && $0.contains("excludes cellular") }, "trace: cellular restriction pattern is labelled as a hypothesis")
		expect(cf.contains { $0.contains("depends on the arrival interface") }, "trace: direct acceptance shows the listener is running")

		// The tunnel itself failing must not be blamed on RemotePairing.
		var broken = ZagTransportTraceResult()
		broken.tunnelInterfaces = ["utun5 10.7.1.1"]
		broken.tunnelLoopback = .failed(.timedOut)
		broken.remotePairingViaTunnel = .failed(.timedOut)
		let bf = ZagTransportTrace.findings(broken)
		expect(bf.contains { $0.contains("case A or B") } && !bf.contains { $0.contains("own TCP stack") },
			"trace: a silent tunnel points at the tunnel, not the listener")

		var wifi = cellular
		wifi.peerPathUsesCellular = false
		wifi.tunnelLoopbackNoCellular = .accepted(milliseconds: 3)
		wifi.remotePairingViaTunnel = .accepted(milliseconds: 3)
		let wf = ZagTransportTrace.findings(wifi)
		expect(!wf.contains { $0.contains("Hypothesis") } && wf.contains { $0.contains("accepted a connection through the tunnel") },
			"trace: the Wi-Fi pattern reports acceptance and no restriction")

		let report = ZagTransportTrace.report(cellular, generatedAt: Date(timeIntervalSince1970: 0), deviceSummary: "iPhone, iOS 27.2")
		expect(report.contains("Findings:") && report.contains("cellular=yes"), "trace: report includes path flags and findings")
	}

	static func endpointTests() {
		// 1, 3. Default and explicit endpoints.
		expect(ZagRPPairingEndpoint.localDevVPN.address == "10.7.0.1", "endpoint: LocalDevVPN uses 10.7.0.1")
		expect(ZagRPPairingEndpoint.loopbackExperimental.address == "127.0.0.1", "endpoint: loopback uses 127.0.0.1")
		// 4. Validation accepts only the two known addresses.
		expect(ZagRPPairingEndpoint.validated("10.7.0.1") == .localDevVPN && ZagRPPairingEndpoint.validated("127.0.0.1") == .loopbackExperimental,
			"endpoint: the two known addresses validate")
		for bad in ["", "localhost", "10.7.1.1", "8.8.8.8", "::1", "127.0.0.1 ", "10.7.0.1:49152"] {
			expect(ZagRPPairingEndpoint.validated(bad) == nil, "endpoint: \"\(bad)\" is rejected")
		}
		// 2, 14. Only the production endpoint can change the toolbar.
		expect(ZagRPPairingEndpoint.localDevVPN.publishesReadiness && !ZagRPPairingEndpoint.loopbackExperimental.publishesReadiness,
			"endpoint: loopback results never publish readiness")

		// 6-10. Loopback failures at each stage keep their classification.
		let cases: [(String, ZagRPPairingFailureKind)] = [
			("Unable to reach RPPairing at 127.0.0.1:49152: Connection refused (os error 61)", .deviceUnreachable),
			("Timed out reaching RPPairing at 127.0.0.1:49152", .deviceUnreachable),
			("RPPairing pair-verify failed: invalid signature", .pairingRejected),
			("RPPairing createListener failed: unexpected response", .sessionSetup),
			("Unable to reach RPPairing tunnel at 127.0.0.1:50211: Connection refused (os error 61)", .sessionSetup),
			("TLS-PSK CDTunnel failed: handshake error", .sessionSetup),
		]
		for (message, kind) in cases {
			let got = ZagRPPairingFailure.classify(message, installationStarted: false)
			expect(got == kind, "endpoint: \"\(message.prefix(48))…\" is \(kind) (got \(got))")
		}
		expect(ZagDiagnosticReport.osErrorCode("Connection refused (os error 61)") == 61, "report: OS error code is extracted")
		expect(ZagDiagnosticReport.osErrorCode("RSD handshake failed: unexpected eof") == nil, "report: no code when none is present")

		let report = ZagDiagnosticReport.make(.init(
			generatedAt: Date(timeIntervalSince1970: 0), iOSVersion: "27.2", deviceModel: "iPhone",
			physicalNetworks: ["Cellular"], tunnelInterfaces: [], model: ZagDeviceLinkModel(),
			endpointProbe: nil, legacyLockdownProbe: nil,
			steps: [
				ZagDiagnosticStep(stage: "Start", detail: "endpoint 127.0.0.1:49152", elapsedMilliseconds: 0, failed: false),
				ZagDiagnosticStep(stage: "After Start", detail: "Unable to reach RPPairing tunnel at 127.0.0.1:50211: Connection refused (os error 61)", elapsedMilliseconds: 812, failed: true),
			],
			sessionFailure: "Unable to reach RPPairing tunnel at 127.0.0.1:50211: Connection refused (os error 61)",
			endpoint: .loopbackExperimental
		))
		expect(report.contains("Target endpoint: 127.0.0.1:49152 (RemotePairing, Loopback (experimental))"), "report: names the loopback target")
		expect(report.contains("Error code: OS error 61") && report.contains("Total duration: 812 ms"), "report: includes error code and total duration")
	}

	static func protocolStageTests() {
		let eof = "RPPairing handshake failed: device socket io failed [idevice code 1; io kind UnexpectedEof; no os error] <- early eof"
		let reset = "RPPairing pair-verify failed: device socket io failed [idevice code 1; io kind ConnectionReset; os error 54] <- Connection reset by peer (os error 54)"
		let rejected = "RPPairing pair-verify failed: pair verify failed [idevice code 72]"
		expect(ZagDiagnosticReport.failingOperation(eof) == "Handshake (attemptPairVerify)", "stage: handshake failure is named")
		expect(ZagDiagnosticReport.failingOperation(reset) == "Pair-Verify (verifyManualPairing)", "stage: pair-verify failure is named")
		expect(ZagDiagnosticReport.failingOperation("Unable to reach RPPairing tunnel at 127.0.0.1:50211: Connection refused (os error 61) [io kind ConnectionRefused; os error 61]") == "TCP connect to tunnel port",
			"stage: tunnel-port failure is named")
		expect(ZagDiagnosticReport.failingOperation("Unable to reach RPPairing at 10.7.0.1:49152: Connection refused (os error 61)") == "TCP connect to 49152",
			"stage: initial connect failure is named")
		expect(ZagDiagnosticReport.ioKind(eof) == "UnexpectedEof" && ZagDiagnosticReport.ioKind(reset) == "ConnectionReset",
			"error: I/O kind is extracted")
		expect(ZagDiagnosticReport.ioKind(rejected) == nil, "error: a protocol rejection has no I/O kind")
		expect(ZagDiagnosticReport.osErrorCode(reset) == 54 && ZagDiagnosticReport.osErrorCode(eof) == nil, "error: OS error is kept only when present")
		expect(ZagRPPairingFailure.classify(eof, installationStarted: false) == .connectionInterrupted, "classify: a handshake EOF is a connection loss")
		expect(ZagRPPairingFailure.classify("RPPairing handshake failed: unexpected response [idevice code 2]", installationStarted: false) == .sessionSetup,
			"classify: a malformed handshake reply is session setup, not rejection")
		expect(ZagRPPairingFailure.classify(rejected, installationStarted: false) == .pairingRejected, "classify: an explicit pair-verify rejection stays a rejection")

		let report = ZagDiagnosticReport.make(.init(
			generatedAt: Date(timeIntervalSince1970: 0), iOSVersion: "27.2", deviceModel: "iPhone",
			physicalNetworks: ["Wi-Fi"], tunnelInterfaces: ["utun5"], model: ZagDeviceLinkModel(),
			endpointProbe: nil, legacyLockdownProbe: nil,
			steps: [
				ZagDiagnosticStep(stage: "Start", detail: "endpoint 127.0.0.1:49152", elapsedMilliseconds: 0, failed: false),
				ZagDiagnosticStep(stage: "TCP connection to 127.0.0.1:49152", detail: "local 127.0.0.1:51234, peer 127.0.0.1:49152", elapsedMilliseconds: 3, failed: false),
				ZagDiagnosticStep(stage: "Handshake started", detail: "", elapsedMilliseconds: 3, failed: false),
				ZagDiagnosticStep(stage: "After Handshake started", detail: eof, elapsedMilliseconds: 86, failed: true),
			],
			sessionFailure: eof, endpoint: .loopbackExperimental
		))
		expect(report.contains("Last successful stage: Handshake started"), "report: last successful stage")
		expect(report.contains("First failing operation: Handshake (attemptPairVerify)"), "report: first failing operation")
		expect(report.contains("I/O error kind: UnexpectedEof") && report.contains("Peer closed the connection: yes"), "report: EOF is reported as the peer closing")
		expect(report.contains("Total duration: 86 ms"), "report: total duration")
	}

	static func idleTests() async throws {
		// A peer that waits for a request keeps the connection open.
		let waiting = try FakeServer(mode: .silent)
		let waitingPort = await waiting.start()
		let open = await ZagTransportTrace.idle(host: "127.0.0.1", port: waitingPort, connectTimeout: 1, wait: 0.5)
		if case .stillOpen = open { expect(true, "idle: a waiting service is kept open") }
		else { expect(false, "idle: waiting service (got \(open))") }
		expect(waiting.requests.isEmpty, "idle: nothing is sent")
		waiting.stop()

		// A peer that closes without any request is reported as rejecting.
		let closing = try FakeServer(mode: .acceptThenClose)
		let closingPort = await closing.start()
		let closed = await ZagTransportTrace.idle(host: "127.0.0.1", port: closingPort, connectTimeout: 1, wait: 1)
		expect(closed.rejectsWithoutRequest, "idle: a peer closing without a request is detected (got \(closed))")
		closing.stop()

		var source = ZagTransportTraceResult()
		source.idleLoopback = .reset(milliseconds: 85)
		source.idleViaTunnel = .stillOpen(waitedMilliseconds: 3000)
		expect(ZagTransportTrace.findings(source).contains { $0.contains("does not depend on what Zag Store sends") },
			"idle: loopback reset with an open tunnel points at how the connection arrives")
		var content = ZagTransportTraceResult()
		content.idleLoopback = .stillOpen(waitedMilliseconds: 3000)
		content.idleViaTunnel = .stillOpen(waitedMilliseconds: 3000)
		expect(ZagTransportTrace.findings(content).contains { $0.contains("after the request is read") },
			"idle: both open points at a check after the request")
	}

	static func mobileDataToggleTests() {
		typealias T = ZagMobileDataToggle
		let t0 = Date(timeIntervalSince1970: 1_800_000_000)
		expect(T.shortcutName == "Zag Mobile Data Toggle" && T.setupActionTitle == "Apply Mobile Data Fix", "toggle: official names")
		expect(T.setupPage.absoluteString == "https://zagstore.app/shortcuts/mobile-data-fix/", "toggle: stable https setup page, no iCloud link in the app")

		// URL generation and command encoding
		let op = T.Operation(id: "6F1C2E9A-1111-4222-8333-944455556666", command: .off, startedAt: t0)
		guard let url = T.launchURL(for: op), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			expect(false, "toggle: launch URL builds"); return
		}
		expect(url.scheme == "shortcuts" && url.host == "x-callback-url" && url.path == "/run-shortcut", "toggle: documented run-shortcut x-callback format")
		let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
		expect(q["name"] == "Zag Mobile Data Toggle", "toggle: name encoded and decoded intact")
		expect(q["input"] == "text" && q["text"] == "off", "toggle: command passed as text input")
		expect(q["x-success"] == "zagstore://shortcut-callback/off/success?id=\(op.id)", "toggle: x-success scoped to command and id")
		expect(q["x-cancel"] == "zagstore://shortcut-callback/off/cancel?id=\(op.id)", "toggle: x-cancel scoped")
		expect(q["x-error"] == "zagstore://shortcut-callback/off/error?id=\(op.id)", "toggle: x-error scoped")
		expect(q.count == 6, "toggle: nested callback parameters stay nested")
		for command in T.Command.allCases {
			let text = T.launchURL(for: .init(id: "x", command: command, startedAt: t0)).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value }
			expect(text == command.rawValue, "toggle: \(command.rawValue) is sent explicitly, never as a toggle")
		}
		let a = T.Operation.new(.status), b = T.Operation.new(.status)
		expect(a.id != b.id && UUID(uuidString: a.id) != nil, "toggle: operation ids are fresh random UUIDs")
		expect(T.Command.status.expectedResult() == "zag-mobile-data-toggle:v1:ready", "toggle: status reply is versioned")
		expect(T.Command.off.expectedResult() == "zag-mobile-data-toggle:v1:off:done", "toggle: off reply")
		expect(T.Command.on.expectedResult() == "zag-mobile-data-toggle:v1:on:done", "toggle: on reply")

		// Callback parsing
		func cb(_ s: String) -> T.Callback? { URL(string: s).flatMap(T.parse) }
		let ok = cb("zagstore://shortcut-callback/off/success?id=\(op.id)&result=zag-mobile-data-toggle%3Av1%3Aoff%3Adone")
		expect(ok?.result == "zag-mobile-data-toggle:v1:off:done" && ok?.parameterNames == ["id", "result"], "callback: result and parameter names read")
		expect(cb("zagstore://shortcut-callback/status/error?id=x&errorMessage=Shortcut%20not%20found")?.errorMessage == "Shortcut not found", "callback: errorMessage read")
		for bad in ["zagstore://shortcut-callback/off/success", "zagstore://shortcut-callback/reboot/success?id=x",
					"zagstore://shortcut-callback/off/maybe?id=x", "zagstore://shortcut-callback/success?id=x"] {
			expect(cb(bad) == nil, "callback: malformed \(bad) rejected")
			expect(URL(string: bad).map(T.isCallback) == true, "callback: malformed \(bad) still kept away from the router")
		}
		for other in ["zagstore://settings", "zagstore://settings/diagnostics/installation/rppairing", "zagstore://apps",
					  "feather://import-certificate?p12=x", "https://zagstore.app/shortcut-callback/off/success?id=x"] {
			expect(URL(string: other).map(T.isCallback) == false, "callback: \(other) left to normal routing")
		}

		// Responses
		expect(T.interpret(" zag-mobile-data-toggle:v1:ready\n") == .ready(version: 1), "response: whitespace tolerated")
		expect(T.interpret("zag-mobile-data-toggle:v2:ready") == .ready(version: 2), "response: other version read")
		expect(T.interpret("zag-mobile-data-toggle:v1:status:done") == .other, "response: status is never a done command")
		expect(T.interpret("zag-mobile-data-toggle:v1:error:unknown-command") == .other, "response: unknown-command reply is not success")
		expect(T.interpret("ready") == .other && T.interpret("") == .missing && T.interpret(nil) == .missing, "response: junk and empty")

		// Validation
		func eval(_ s: String, _ pending: T.Operation?, at: Date = t0.addingTimeInterval(2)) -> T.Decision {
			T.evaluate(cb(s)!, pending: pending, now: at)
		}
		let base = "zagstore://shortcut-callback/off/success?id=\(op.id)&result="
		expect(eval(base + "zag-mobile-data-toggle:v1:off:done", op) == .complete(.confirmed), "validate: matching reply confirmed")
		expect(eval(base + "zag-mobile-data-toggle:v1:off:done", nil) == .ignore("no operation is waiting"), "validate: duplicate after completion ignored")
		if case .ignore = eval("zagstore://shortcut-callback/off/success?id=OTHER&result=zag-mobile-data-toggle:v1:off:done", op) {} else { expect(false, "validate: wrong id ignored") }
		if case .ignore = eval("zagstore://shortcut-callback/on/success?id=\(op.id)&result=zag-mobile-data-toggle:v1:on:done", op) {} else { expect(false, "validate: wrong command ignored") }
		if case .ignore = eval(base + "zag-mobile-data-toggle:v1:off:done", op, at: t0.addingTimeInterval(T.operationLifetime + 1)) {} else { expect(false, "validate: expired operation ignored") }
		expect(eval(base + "zag-mobile-data-toggle:v1:on:done", op) == .complete(.unexpectedResult), "validate: reply for the other command rejected")
		expect(eval(base + "zag-mobile-data-toggle:v1:ready", op) == .complete(.unexpectedResult), "validate: status reply to off rejected")
		expect(eval("zagstore://shortcut-callback/off/success?id=\(op.id)", op) == .complete(.missingResult), "validate: success without result is not proof")
		expect(eval("zagstore://shortcut-callback/off/cancel?id=\(op.id)", op) == .complete(.cancelled), "validate: cancel")
		expect(eval("zagstore://shortcut-callback/off/error?id=\(op.id)&errorMessage=not%20found", op) == .complete(.failed(message: "not found")), "validate: missing Shortcut reported as error")
		let st = T.Operation(id: "S", command: .status, startedAt: t0)
		expect(eval("zagstore://shortcut-callback/status/success?id=S&result=zag-mobile-data-toggle:v1:ready", st) == .complete(.confirmed), "validate: status v1 confirmed")
		expect(eval("zagstore://shortcut-callback/status/success?id=S&result=zag-mobile-data-toggle:v2:ready", st) == .complete(.incompatible(found: 2)), "validate: other version is incompatible")
		expect(eval("zagstore://shortcut-callback/status/success?id=S&result=hello", st) == .complete(.unexpectedResult), "validate: wrong reply rejected")

		// Stored state
		var r = T.Record()
		expect(T.status(of: r, now: t0) == .notSetUp, "status: not set up")
		expect(T.Status.failed(reason: "x").title == "Failed", "status: a failed verification is labelled Failed")
		expect(T.Status.verified(version: 1, at: t0).title == "Verified", "status: success is still labelled Verified")
		r.setupPageOpenedAt = t0
		if case .verificationRequired = T.status(of: r, now: t0) {} else { expect(false, "status: opening the website does not verify") }
		r = T.record(r, after: .confirmed, now: t0)
		expect(T.status(of: r, now: t0.addingTimeInterval(3600)) == .verified(version: 1, at: t0), "status: verified after handshake")
		if case .verificationRequired = T.status(of: r, now: t0.addingTimeInterval(T.verificationLifetime + 1)) {} else { expect(false, "status: stale verification needs re-checking") }
		expect(T.record(r, after: .cancelled, now: t0) == r, "status: cancel leaves state alone")
		let failed = T.record(r, after: .failed(message: "not found"), now: t0.addingTimeInterval(10))
		if case .failed = T.status(of: failed, now: t0.addingTimeInterval(11)) {} else { expect(false, "status: a failure withdraws Verified") }
		for c in [T.Completion.noResponse, .timedOut, .missingResult, .unexpectedResult, .handOffRejected] {
			if case .failed = T.status(of: T.record(r, after: c, now: t0.addingTimeInterval(5)), now: t0.addingTimeInterval(6)) {} else { expect(false, "status: \(c) withdraws Verified") }
		}
		expect(T.status(of: T.record(failed, after: .confirmed, now: t0.addingTimeInterval(20)), now: t0.addingTimeInterval(21)).isVerified, "status: a new handshake recovers")
		expect(T.status(of: T.record(r, after: .incompatible(found: 2), now: t0), now: t0) == .updateRequired(found: 2), "status: update required")
		var old = r; old.verifiedVersion = 0
		if case .verificationRequired = T.status(of: old, now: t0) {} else { expect(false, "status: an older verified protocol needs re-checking") }
		var future = r; future.verifiedAt = t0.addingTimeInterval(86_400)
		if case .verificationRequired = T.status(of: future, now: t0) {} else { expect(false, "status: a verification dated in the future is not trusted") }
		let roundTrip = try? JSONDecoder().decode(T.Record.self, from: JSONEncoder().encode(r))
		expect(roundTrip == r, "status: record survives storage")
		expect(!T.message(for: .failed(message: String(repeating: "x", count: 500))).contains(String(repeating: "x", count: 200)), "status: Shortcuts error text is truncated")
	}

	@MainActor final class FakeMobileData {
		typealias Command = ZagMobileDataToggle.Command
		var networks: [ZagMobileDataNetwork] = [.wifi]
		var endpoints: [ZagMobileDataEndpoint] = [.reachable]
		var tunnel = true
		var ready = true
		var consent: ZagMobileDataConsent = .allowed
		var replies: [Command: ZagMobileDataToggle.Completion] = [.off: .confirmed, .on: .confirmed]
		var record: ZagMobileDataRecoveryRecord?
		var calls: [String] = []
		var stages: [ZagMobileDataInstallStage] = []
		var endpointChecks = 0
		var recordSavedBeforeOff: Bool?
		var operationError: Error?
		var holdOperation = false
		var heldOperation: CheckedContinuation<Void, Never>?
		var operationName = "install"

		private func next<T>(_ list: inout [T]) -> T { list.count > 1 ? list.removeFirst() : list[0] }

		var environment: ZagMobileDataInstallFlow.Environment {
			ZagMobileDataInstallFlow.Environment(
				network: { [unowned self] in self.next(&self.networks) },
				endpoint: { [unowned self] in self.endpointChecks += 1; return self.next(&self.endpoints) },
				tunnelPresent: { [unowned self] in self.tunnel },
				shortcutReady: { [unowned self] in self.ready },
				consent: { [unowned self] in self.calls.append("consent"); return self.consent },
				runShortcut: { [unowned self] command in
					if command == .off { self.recordSavedBeforeOff = self.record != nil }
					self.calls.append(command.rawValue)
					return self.replies[command] ?? .confirmed
				},
				waitUntilActive: {},
				sleep: { _ in },
				now: { Date(timeIntervalSince1970: 1_800_000_000) },
				loadRecord: { [unowned self] in self.record },
				saveRecord: { [unowned self] in self.record = $0 },
				stage: { [unowned self] in self.stages.append($0) },
				log: { _ in }
			)
		}

		/// Stands in for installGate4IPA or uninstallGate4App.
		func operation() async throws {
			calls.append(operationName)
			if holdOperation { await withCheckedContinuation { heldOperation = $0 } }
			if let operationError { throw operationError }
		}

		func run(job: String = "job-1") async -> ZagMobileDataInstallOutcome {
			let flow = ZagMobileDataInstallFlow(environment: environment)
			return await flow.run(jobID: job) { try await self.operation() }
		}

		/// The device failure: Wi-Fi off, Mobile Data on, LocalDevVPN up,
		/// installer refused (os 61). After `off` the port answers; after
		/// `on` it refuses again.
		static func mobileDataBlocked(_ interfaces: ZagMobileDataNetwork = .cellular) -> FakeMobileData {
			let f = FakeMobileData()
			f.networks = [interfaces]
			f.endpoints = [.refused, .reachable, .refused]
			return f
		}
	}

	struct FakeInstallError: Error {}

	@MainActor static func mobileDataInstallTests() async {
		let off = ZagMobileDataToggle.Command.off, on = ZagMobileDataToggle.Command.on

		// Regression: the device failure. The old flow needed the interface
		// list to be exactly ["Cellular"]; any other report went straight to
		// the installer, which failed with os 61 and never ran the Shortcut.
		for listed in [ZagMobileDataNetwork.cellular, .other, .none] {
			let f = FakeMobileData.mobileDataBlocked(listed)
			let o = await f.run()
			expect(f.calls == ["consent", "off", "install", "on"] && o.installed && o.restoration == .restored && f.record == nil,
				"regression: refused through LocalDevVPN with interfaces \(listed) runs OFF → install → ON (calls \(f.calls))")
		}
		expect(ZagMobileDataNetwork.classify(["Cellular", "Cellular"]) == .cellular, "classify: several Mobile Data interfaces are Mobile Data")
		expect(ZagMobileDataNetwork.classify(["Cellular", "Wired"]) == .cellular, "classify: Mobile Data with another interface is Mobile Data")
		expect(ZagMobileDataNetwork.classify(["Cellular", "Wi-Fi"]) == .wifi && ZagMobileDataNetwork.classify([]) == .none, "classify: Wi-Fi wins; nothing listed is none")

		// Wi-Fi: no Shortcut, no probe
		var f = FakeMobileData()
		var o = await f.run()
		expect(f.calls == ["install"] && f.endpointChecks == 0 && o.installed && !o.usedMobileDataFix, "install: Wi-Fi installs directly with no Shortcut")
		f = FakeMobileData(); f.operationName = "uninstall"
		o = await f.run()
		expect(f.calls == ["uninstall"] && o.installed, "uninstall: Wi-Fi removes directly with no Shortcut")

		// Unrelated failures never turn Mobile Data off
		f = FakeMobileData(); f.networks = [.wifi]; f.endpoints = [.refused]
		o = await f.run()
		expect(f.calls == ["install"], "install: a refusal on Wi-Fi is not a Mobile Data block")
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused]; f.tunnel = false
		o = await f.run()
		expect(f.calls == ["install"], "install: a refusal without LocalDevVPN is not a Mobile Data block")
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.unreachable]
		o = await f.run()
		expect(f.calls == ["install"], "install: no answer at all (LocalDevVPN down) keeps today's behaviour")

		// Order, record and stages
		f = FakeMobileData.mobileDataBlocked()
		o = await f.run()
		expect(f.recordSavedBeforeOff == true && f.record == nil, "install: recovery record saved before off, cleared once Mobile Data is back")
		expect(f.stages == [.checkingConnection, .disablingMobileData, .connecting, .installing, .restoringMobileData, .idle], "install: stages in order")
		expect(f.calls.filter { $0 == "off" }.count == 1 && f.calls.filter { $0 == "on" }.count == 1, "install: one OFF and one ON per job")

		// Uninstall: same safeguards; failure is reported, never success
		f = FakeMobileData.mobileDataBlocked(); f.operationName = "uninstall"
		o = await f.run()
		expect(f.calls == ["consent", "off", "uninstall", "on"] && o.installed, "uninstall: Mobile Data runs OFF → uninstall → ON")
		f = FakeMobileData.mobileDataBlocked(); f.operationName = "uninstall"; f.operationError = FakeInstallError()
		o = await f.run()
		expect(!o.installed && o.installError != nil && o.restoration == .restored && f.calls.last == "on", "uninstall: a failed uninstall is reported as failed and Mobile Data is restored")

		// Shortcut not ready / missing
		f = FakeMobileData.mobileDataBlocked(); f.ready = false
		o = await f.run()
		expect(o.notAttempted == .shortcutNotReady && f.calls.isEmpty && f.record == nil, "install: unverified Shortcut is never run")
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused]; f.replies[off] = .failed(message: "not found")
		o = await f.run()
		expect(o.notAttempted == .connectionUnavailable && f.calls == ["consent", "off"] && f.record == nil && o.restoration == .notChanged, "install: deleted Shortcut fails without ON (installer still refused)")

		// OFF callback lost or late
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused]; f.replies[off] = .timedOut
		o = await f.run()
		expect(f.calls.filter { $0 == "off" }.count == 1 && !f.calls.contains("on") && o.notAttempted == .connectionUnavailable, "install: OFF timeout with Mobile Data still on is not retried")
		f = FakeMobileData.mobileDataBlocked(); f.replies[off] = .noResponse
		o = await f.run()
		expect(f.calls == ["consent", "off", "install", "on"] && o.installed, "install: lost OFF callback continues once the installer answers, without resending off")

		// Unreachable after OFF while Mobile Data is off (no answer): restore
		f = FakeMobileData(); f.networks = [.cellular, .none, .cellular]; f.endpoints = [.refused, .unreachable]
		o = await f.run()
		expect(o.notAttempted == .connectionUnavailable && f.calls == ["consent", "off", "on"] && o.restoration == .restored, "install: unreachable after OFF restores Mobile Data")

		// Operation failure
		f = FakeMobileData.mobileDataBlocked(); f.operationError = FakeInstallError()
		o = await f.run()
		expect(o.installError != nil && !o.installed && o.restoration == .restored, "install: failure is reported separately from restoration")

		// Cancellation
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused]; f.replies[off] = .cancelled
		o = await f.run()
		expect(o.notAttempted == .cancelled && f.calls == ["consent", "off"] && f.record == nil, "install: cancel in Shortcuts installs nothing and sends no ON")
		f = FakeMobileData.mobileDataBlocked(); f.replies[off] = .cancelled
		o = await f.run()
		expect(o.notAttempted == .cancelled && f.calls == ["consent", "off", "on"], "install: cancel after Mobile Data went off restores it and installs nothing")
		f = FakeMobileData.mobileDataBlocked()
		let cancelled = Task { @MainActor in await f.run() }
		cancelled.cancel()
		o = await cancelled.value
		expect(o.notAttempted == .cancelled && !f.calls.contains("off") && f.record == nil, "install: a cancelled task never turns Mobile Data off")

		// Restoration not confirmed (installer keeps answering = still off)
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused, .reachable]; f.replies[on] = .timedOut
		o = await f.run()
		expect(o.installed && o.restoration == .unconfirmed && f.calls.filter { $0 == "on" }.count == 1 && f.record?.onRequestedAt != nil, "install: ON timeout is not retried and leaves a recovery record")
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused, .reachable]; f.replies[on] = .failed(message: "x")
		o = await f.run()
		expect(o.installed && o.restoration == .unconfirmed && f.record != nil, "install: success with restoration failure reports both")
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused, .reachable]
		o = await f.run()
		expect(o.restoration == .unconfirmed, "install: an ON reply alone is not proof; the installer still answering means not restored")

		// Relaunch after termination
		f = FakeMobileData(); f.record = ZagMobileDataRecoveryRecord(jobID: "old", offRequestedAt: .distantPast)
		f.networks = [.none]; f.endpoints = [.reachable]
		o = await f.run(job: "job-2")
		expect(o.installed && f.calls == ["install"] && f.record?.jobID == "old", "relaunch: Mobile Data still off → installs directly, keeps the old record, sends no ON")
		f = FakeMobileData.mobileDataBlocked(); f.record = ZagMobileDataRecoveryRecord(jobID: "old", offRequestedAt: .distantPast)
		o = await f.run(job: "job-2")
		expect(o.installed && f.record == nil && f.calls == ["consent", "off", "install", "on"], "relaunch: refusal shows Mobile Data back on and resolves the old record")

		// Repeated taps
		f = FakeMobileData(); f.holdOperation = true
		let flow = ZagMobileDataInstallFlow(environment: f.environment)
		let first = Task { @MainActor in await flow.run(jobID: "a") { try await f.operation() } }
		for _ in 0..<50 where f.heldOperation == nil { await Task.yield() }
		let second = await flow.run(jobID: "b") { try await f.operation() }
		f.heldOperation?.resume()
		let firstOutcome = await first.value
		expect(second.notAttempted == .alreadyRunning && firstOutcome.installed && f.calls == ["install"], "install: a second tap while one is running is rejected")

		// Mobile Data already off: never turned on
		f = FakeMobileData(); f.networks = [.none]; f.endpoints = [.reachable]
		o = await f.run()
		expect(f.calls == ["install"] && o.restoration == .notChanged, "install: Mobile Data already off is left off")

		// Consent
		f = FakeMobileData.mobileDataBlocked(); f.consent = .declined
		o = await f.run()
		expect(o.notAttempted == .consentDeclined && f.calls == ["consent"] && f.record == nil, "install: Not Now changes nothing")
		f = FakeMobileData.mobileDataBlocked(); f.consent = .disabled
		o = await f.run()
		expect(o.notAttempted == .automaticDisabled && !f.calls.contains("off"), "install: switched-off automatic handling changes nothing")

		// Automatic eligibility
		typealias T = ZagMobileDataToggle
		let t0 = Date(timeIntervalSince1970: 1_800_000_000)
		var r = T.record(T.Record(), after: .confirmed, now: t0)
		expect(T.canRunAutomatically(r, now: t0), "auto: verified Shortcut may run")
		expect(T.canRunAutomatically(r, now: t0.addingTimeInterval(T.verificationLifetime + 10)), "auto: a stale v1 verification may run (reply still checked)")
		expect(!T.canRunAutomatically(T.Record(), now: t0), "auto: never without verification")
		r = T.record(r, after: .failed(message: nil), now: t0.addingTimeInterval(5))
		expect(!T.canRunAutomatically(r, now: t0.addingTimeInterval(6)), "auto: never after a failure")
		expect(!T.canRunAutomatically(T.record(T.Record(), after: .incompatible(found: 2), now: t0), now: t0), "auto: never with another version")
	}

	@MainActor final class FakeUninstall {
		var busyPolls = 0
		var busyForever = false
		var reply: Result<Void, Error> = .success(())
		var replyDelaySteps = 0
		var lists: [Result<Set<String>, Error>] = [.success(["other.app"])]
		var calls: [String] = []
		var clock: TimeInterval = 0

		struct Lost: LocalizedError { var errorDescription: String? { "RPPairing pair-verify failed: socket io failed" } }

		var environment: ZagRPPairingUninstall.Environment {
			ZagRPPairingUninstall.Environment(
				transportBusy: { [unowned self] in
					if self.busyForever { return true }
					if self.busyPolls > 0 { self.busyPolls -= 1; return true }
					return false
				},
				uninstall: { [unowned self] id in
					self.calls.append("uninstall:\(id)")
					for _ in 0..<self.replyDelaySteps { self.clock += 1; await Task.yield() }
					self.calls.append("reply")
					return self.reply
				},
				installedApps: { [unowned self] in
					self.calls.append("verify")
					return self.lists.count > 1 ? self.lists.removeFirst() : self.lists[0]
				},
				sleep: { [unowned self] in self.clock += $0 },
				now: { [unowned self] in Date(timeIntervalSince1970: self.clock) },
				log: { _ in }
			)
		}

		func run(_ id: String = "com.example.app") async -> Result<ZagRPPairingUninstallConfirmation, Error> {
			do { return .success(try await ZagRPPairingUninstall(env: environment).run(bundleID: id)) }
			catch { return .failure(error) }
		}
	}

	@MainActor static func uninstallTests() async {
		let id = "com.example.app"
		func failure(_ r: Result<ZagRPPairingUninstallConfirmation, Error>) -> ZagRPPairingUninstallFailure? {
			if case .failure(let e) = r { return e as? ZagRPPairingUninstallFailure }
			return nil
		}

		// Unit behaviour
		var u = FakeUninstall()
		var r = await u.run()
		expect((try? r.get()) == .verified && u.calls == ["uninstall:\(id)", "reply", "verify"], "uninstall: submitted once, confirmed by a fresh device list")
		u = FakeUninstall(); u.busyPolls = 6
		r = await u.run()
		expect((try? r.get()) == .verified && u.calls.first == "uninstall:\(id)" && u.clock >= 3, "uninstall: waits for a busy connection (app-list refresh after Shortcuts) before submitting")
		u = FakeUninstall(); u.busyForever = true
		r = await u.run()
		expect(failure(r) == .connectionBusy && u.calls.isEmpty, "uninstall: a connection busy for the whole wait is not submitted and fails")
		u = FakeUninstall(); u.replyDelaySteps = 5
		r = await u.run()
		expect((try? r.get()) == .verified && u.calls == ["uninstall:\(id)", "reply", "verify"], "uninstall: delayed completion is awaited before verification")
		u = FakeUninstall(); u.lists = [.success([id]), .success([id]), .success(["other.app"])]
		r = await u.run()
		expect((try? r.get()) == .verified && u.calls.filter { $0 == "verify" }.count == 3, "uninstall: a stale list that still shows the app is re-read until it is gone")
		u = FakeUninstall(); u.lists = [.success([id])]
		r = await u.run()
		expect(failure(r) == .stillInstalled && u.calls.filter { $0 == "verify" }.count == ZagRPPairingUninstall.verifyDelays.count, "uninstall: still listed after every read is a verification timeout, not success")
		u = FakeUninstall(); u.reply = .failure(FakeUninstall.Lost())
		r = await u.run()
		if case .requestFailed(let m)? = failure(r) {
			expect(m.contains("pair-verify") && !u.calls.contains("verify"), "uninstall: request failure or connection loss is reported with its reason; nothing verified")
		} else { expect(false, "uninstall: request failure is reported") }
		u = FakeUninstall(); u.lists = [.failure(FakeUninstall.Lost())]
		r = await u.run()
		expect((try? r.get()) == .serviceCompleted, "uninstall: connection lost during verification keeps the installation service's completion")
		u = FakeUninstall(); u.lists = [.failure(FakeUninstall.Lost()), .success([id])]
		r = await u.run()
		expect(failure(r) == .stillInstalled, "uninstall: one failed read then still listed is a failure")
		u = FakeUninstall()
		let cancelled = Task { @MainActor in await u.run() }
		cancelled.cancel()
		r = await cancelled.value
		expect(failure(r) == .cancelled && u.calls.isEmpty, "uninstall: cancelled before submission removes nothing")

		// Inside the Mobile Data flow: OFF → uninstall → verified → ON
		func flowRun(_ f: FakeMobileData, _ u: FakeUninstall) async -> ZagMobileDataInstallOutcome {
			let env = u.environment
			var wrapped = env
			wrapped.uninstall = { id in f.calls.append("uninstall"); let r = await env.uninstall(id); f.calls.append("reply"); return r }
			wrapped.installedApps = { f.calls.append("verify"); return await env.installedApps() }
			let flow = ZagMobileDataInstallFlow(environment: f.environment)
			return await flow.run(jobID: "uninstall-\(id)") {
				_ = try await ZagRPPairingUninstall(env: wrapped).run(bundleID: id)
			}
		}
		func onIsLast(_ calls: [String]) -> Bool {
			guard let on = calls.lastIndex(of: "on") else { return false }
			return calls.indices.filter { ["uninstall", "reply", "verify"].contains(calls[$0]) }.allSatisfy { $0 < on }
		}

		var f = FakeMobileData.mobileDataBlocked()
		u = FakeUninstall(); u.lists = [.success([id]), .success([])]
		var o = await flowRun(f, u)
		expect(f.calls == ["consent", "off", "uninstall", "reply", "verify", "verify", "on"] && o.installed && o.restoration == .restored,
			"mobile data uninstall: OFF → uninstall → verified removal → ON (\(f.calls))")
		f = FakeMobileData.mobileDataBlocked(); u = FakeUninstall(); u.replyDelaySteps = 8; u.busyPolls = 4
		o = await flowRun(f, u)
		expect(onIsLast(f.calls) && o.installed, "mobile data uninstall: ON never precedes a delayed reply or verification")
		f = FakeMobileData.mobileDataBlocked(); u = FakeUninstall(); u.reply = .failure(FakeUninstall.Lost())
		o = await flowRun(f, u)
		expect(!o.installed && o.restoration == .restored && onIsLast(f.calls), "mobile data uninstall: request failure is reported, then Mobile Data is restored")
		f = FakeMobileData.mobileDataBlocked(); u = FakeUninstall(); u.lists = [.success([id])]
		o = await flowRun(f, u)
		expect(!o.installed && (o.installError as? ZagRPPairingUninstallFailure) == .stillInstalled && onIsLast(f.calls), "mobile data uninstall: verification timeout is a failure, restored after verification ends")
		f = FakeMobileData.mobileDataBlocked(); u = FakeUninstall(); u.busyForever = true
		o = await flowRun(f, u)
		expect(!o.installed && !f.calls.contains("uninstall") && f.calls.last == "on", "mobile data uninstall: busy connection fails without submitting; Mobile Data restored")
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused, .reachable]; f.replies[.on] = .timedOut
		u = FakeUninstall()
		o = await flowRun(f, u)
		expect(o.installed && o.restoration == .unconfirmed && f.record != nil, "mobile data uninstall: removal confirmed but restoration unconfirmed reports both and keeps recovery")
		f = FakeMobileData(); u = FakeUninstall()
		o = await flowRun(f, u)
		expect(o.installed && !f.calls.contains("off") && !f.calls.contains("on"), "wifi uninstall: no Shortcut")
	}

	@MainActor static func inventoryTests() async {
		let id = "com.example.new"
		struct Refused: LocalizedError { var errorDescription: String? { "Connection refused (os error 61)" } }
		final class Device {
			var lists: [Result<Set<String>, Error>]
			var busy = 0
			var reads = 0
			var clock: TimeInterval = 0
			init(_ lists: [Result<Set<String>, Error>]) { self.lists = lists }
		}
		@MainActor func env(_ d: Device, _ calls: (() -> Void)? = nil) -> ZagRPPairingInventoryCheck.Environment {
			.init(
				transportBusy: { if d.busy > 0 { d.busy -= 1; return true }; return false },
				installedApps: { d.reads += 1; calls?(); return d.lists.count > 1 ? d.lists.removeFirst() : d.lists[0] },
				sleep: { d.clock += $0 },
				now: { Date(timeIntervalSince1970: d.clock) },
				log: { _ in }
			)
		}
		let t0 = Date(timeIntervalSince1970: 0)

		var d = Device([.success([id, "other"])])
		var o = await ZagRPPairingInventoryCheck(env: env(d)).run(bundleID: id, expectInstalled: true, label: "Inventory", start: t0)
		expect(o.confirmed && o.list == [id, "other"] && d.reads == 1, "inventory: a new install is confirmed by one fresh read")
		d = Device([.success(["other"]), .success(["other"]), .success([id])])
		o = await ZagRPPairingInventoryCheck(env: env(d)).run(bundleID: id, expectInstalled: true, label: "Inventory", start: t0)
		expect(o.confirmed && d.reads == 3, "inventory: a delayed listing is re-read until the app appears")
		d = Device([.success(["other"])])
		o = await ZagRPPairingInventoryCheck(env: env(d)).run(bundleID: id, expectInstalled: true, label: "Inventory", start: t0)
		expect(!o.confirmed && o.list == ["other"] && d.reads == ZagRPPairingInventoryCheck.delays.count, "inventory: never listed is not confirmed, and the latest list is kept")
		d = Device([.failure(Refused())])
		o = await ZagRPPairingInventoryCheck(env: env(d)).run(bundleID: id, expectInstalled: true, label: "Inventory", start: t0)
		expect(!o.confirmed && o.list == nil, "inventory: a refused read (Mobile Data already back on) gives no list, so nothing is marked")
		d = Device([.success([id])]); d.busy = 4
		o = await ZagRPPairingInventoryCheck(env: env(d)).run(bundleID: id, expectInstalled: true, label: "Inventory", start: t0)
		expect(o.confirmed && d.clock >= 2, "inventory: waits for a busy connection before reading")
		d = Device([.success(["x"])])
		o = await ZagRPPairingInventoryCheck(env: env(d)).run(bundleID: nil, expectInstalled: true, label: "Inventory", start: t0)
		expect(o.confirmed && d.reads == 1, "inventory: without a bundle ID one read is enough")

		// Inside the Mobile Data flow, as the coordinator runs it
		func installRun(_ f: FakeMobileData, _ d: Device, fail: Bool = false) async -> (ZagMobileDataInstallOutcome, Set<String>?) {
			var snapshot: Set<String>?
			let flow = ZagMobileDataInstallFlow(environment: f.environment)
			let outcome = await flow.run(jobID: "signed-1") {
				f.calls.append("install")
				if fail { throw FakeInstallError() }
				if f.stages.contains(.disablingMobileData) {
					let r = await ZagRPPairingInventoryCheck(env: env(d) { f.calls.append("inventory") })
						.run(bundleID: id, expectInstalled: true, label: "Inventory", start: t0)
					snapshot = r.list
				}
			}
			return (outcome, snapshot)
		}
		func installedSection(_ snapshot: Set<String>?) -> Bool { snapshot?.contains(id) ?? false }

		var f = FakeMobileData.mobileDataBlocked()
		d = Device([.success(["other"]), .success([id])])
		var (out, snap) = await installRun(f, d)
		expect(f.calls == ["consent", "off", "install", "inventory", "inventory", "on"] && out.installed && installedSection(snap),
			"signed → installed (Mobile Data): the device list is read before ON and confirms the install (\(f.calls))")
		f = FakeMobileData(); d = Device([.success([id])])
		(out, snap) = await installRun(f, d)
		expect(f.calls == ["install"] && snap == nil && out.installed, "signed → installed (Wi-Fi): no capture; the existing query confirms as before")
		f = FakeMobileData.mobileDataBlocked(); d = Device([.success([id])])
		(out, snap) = await installRun(f, d, fail: true)
		expect(!out.installed && snap == nil && !f.calls.contains("inventory") && f.calls.last == "on", "signed (failed install): no device list, stays Signed, Mobile Data restored")
		f = FakeMobileData.mobileDataBlocked(); d = Device([.success(["other"])])
		(out, snap) = await installRun(f, d)
		expect(out.installed && !installedSection(snap), "signed (installer success, never listed): not marked Installed without the device confirming")
		f = FakeMobileData.mobileDataBlocked(); d = Device([.failure(Refused())])
		(out, snap) = await installRun(f, d)
		expect(snap == nil && f.calls.last == "on", "signed (list unreadable): nothing marked; Mobile Data restored")
	}

	static func badgeTests() {
		let t0 = Date(timeIntervalSince1970: 1_800_000_000)
		func model(_ result: ZagEndpointProbeResult?, interface: Bool = true, pairing: ZagRPPairingReadiness? = nil) -> ZagDeviceLinkModel {
			var m = ZagDeviceLinkModel()
			if let result { m.probeStarted(); m.probeFinished(result, interfacePresent: interface, startedAt: t0, finishedAt: t0.addingTimeInterval(1)) }
			if let pairing { m.pairingEvent(pairing) }
			return m
		}
		func badge(_ m: ZagDeviceLinkModel, wifi: Bool = false, ready: Bool = false, running: Bool = false) -> ZagLocalVPNBadge {
			ZagLocalVPNBadge.make(model: m, wifiConnected: wifi, mobileDataFixReady: ready, mobileDataFixRunning: running)
		}
		let reachable = model(.accepted(milliseconds: 12))
		let refused = model(.failed(.refused))
		let disconnected = model(.failed(.timedOut), interface: false)

		expect(badge(reachable, wifi: true) == .reachable, "badge: Wi-Fi with RPPairing reachable is green (reachable)")
		expect(badge(reachable, wifi: false, ready: true) == .reachable, "badge: a reachable endpoint stays reachable, never relabelled as the fix")
		expect(badge(refused, ready: true) == .mobileDataFixReady, "badge: Mobile Data + LocalDevVPN + authorised verified fix is green (fix ready)")
		expect(badge(refused, ready: true) != .reachable, "badge: the fix never claims the endpoint is directly reachable")
		expect(badge(refused, ready: false) == .attention, "badge: Mobile Data with the fix unavailable or unauthorised is amber")
		expect(badge(refused, wifi: true, ready: true) == .attention, "badge: a refusal on Wi-Fi is amber, not the Mobile Data fix")
		expect(badge(model(.failed(.reset)), ready: true) == .attention, "badge: a reset is not the Mobile Data block")
		expect(badge(disconnected) == .failed && badge(disconnected, ready: true) == .failed, "badge: LocalDevVPN disconnected is red")
		expect(badge(model(.failed(.timedOut), interface: true)) == .attention, "badge: tunnel present but silent is amber")
		expect(badge(model(.accepted(milliseconds: 5), pairing: .failed(.pairingRejected, t0.addingTimeInterval(5)))) == .failed, "badge: rejected credentials are red")
		expect(badge(model(.accepted(milliseconds: 5), pairing: .failed(.connectionInterrupted, t0.addingTimeInterval(5)))) == .attention, "badge: a transient session failure is amber")
		for m in [refused, disconnected, reachable, model(nil)] {
			expect(badge(m, ready: true, running: true) == .working, "badge: a running Mobile Data Fix shows working, never failure")
		}
		expect(badge(model(nil)) == .unknown, "badge: nothing checked yet is neutral")
		var checking = ZagDeviceLinkModel(); checking.probeStarted()
		expect(badge(checking) == .checking, "badge: a first check in progress is neutral")
	}

	static func main() async {
		parserTests()
		schedulerTests()
		modelTests()
		reportTests()
		endpointTests()
		protocolStageTests()
		mobileDataToggleTests()
		await mobileDataInstallTests()
		badgeTests()
		await uninstallTests()
		await inventoryTests()
		installJobTests()
		resumeHelperTests()
		await pauseResumeTests()
		await installCancelTests()
		classificationTests()
		retryTests()
		do { try await probeTests() } catch { expect(false, "probe tests threw \(error)") }
		do { try await traceTests() } catch { expect(false, "trace tests threw \(error)") }
		do { try await idleTests() } catch { expect(false, "idle tests threw \(error)") }
		if failures > 0 {
			print("\(failures) device link test(s) failed")
			exit(1)
		}
		print("All device link tests passed")
	}
}

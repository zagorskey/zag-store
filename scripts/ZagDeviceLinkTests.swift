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
		expect(live.steps.count == 9, "trace: every stage is timestamped (got \(live.steps.count))")
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

	static func main() async {
		parserTests()
		schedulerTests()
		modelTests()
		reportTests()
		endpointTests()
		protocolStageTests()
		classificationTests()
		retryTests()
		do { try await probeTests() } catch { expect(false, "probe tests threw \(error)") }
		do { try await traceTests() } catch { expect(false, "trace tests threw \(error)") }
		if failures > 0 {
			print("\(failures) device link test(s) failed")
			exit(1)
		}
		print("All device link tests passed")
	}
}

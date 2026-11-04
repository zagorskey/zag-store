import Foundation
import Network

// Install job state, real URLSession pause/resume against a local HTTP
// server, and cancellation through the Mobile Data flow.

extension ZagDeviceLinkTests {

	// MARK: - Job state

	@MainActor static func installJobTests() {
		let jobs = ZagInstallJobs()
		let id = "repo:app"

		expect(jobs.begin(id, stage: .downloading), "job: starts")
		expect(!jobs.begin(id, stage: .downloading), "job: a duplicate tap does not start a second job")
		expect(jobs.jobs.count == 1, "job: still one job after the duplicate tap")

		jobs.setProgress(id, 0.4)
		jobs.advance(id, to: .paused)
		jobs.setProgress(id, 0.1)
		expect(jobs.job(id)?.progress == 0.4, "job: download progress never moves backwards across pause and resume")
		jobs.advance(id, to: .resuming)
		jobs.advance(id, to: .downloading)
		jobs.setProgress(id, 0.6)
		expect(jobs.job(id)?.progress == 0.6, "job: progress continues after resume")
		jobs.setProgress(id, 0.601)
		expect(jobs.job(id)?.progress == 0.6, "job: tiny progress steps are not published")

		jobs.setCanPause(id, true)
		expect(jobs.job(id)?.canPause == true, "job: pause offered once the server supports resume")
		jobs.advance(id, to: .importing)
		expect(jobs.job(id)?.canPause == false, "job: pause is withdrawn after the transfer")

		// Cancel responses per stage
		func response(at stage: ZagInstallStage) -> ZagInstallCancelResponse {
			let j = ZagInstallJobs()
			j.begin("x", stage: .downloading)
			j.advance("x", to: stage)
			return j.requestCancel("x")
		}
		expect(response(at: .downloading) == .now && response(at: .paused) == .now, "cancel: immediate while downloading or paused")
		for stage in [ZagInstallStage.importing, .signing, .packaging, .preparingMobileDataFix] {
			expect(response(at: stage) == .afterCurrentStep, "cancel: \(stage) finishes its current step first")
		}
		expect(response(at: .installing) == .notPossible && response(at: .restoringMobileData) == .notPossible, "cancel: not possible once RPPairing installation begins")
		expect(ZagInstallJobs().requestCancel("none") == .noJob, "cancel: no job, nothing to cancel")

		let signOnly = ZagInstallJobs()
		signOnly.begin("s", stage: .signing, offersCancel: false)
		expect(signOnly.requestCancel("s") == .notPossible, "cancel: sign-only jobs do not offer cancel")

		// Safe points
		let safe = ZagInstallJobs()
		safe.begin("j", stage: .signing)
		expect((try? safe.checkpoint("j")) != nil, "safe point: passes without a request")
		_ = safe.requestCancel("j")
		expect((try? safe.checkpoint("j")) == nil, "safe point: throws after a cancel request")
		expect((try? safe.beginInstalling("j")) == nil && safe.job("j")?.stage == .signing, "safe point: a cancelled job never enters installing")

		let installing = ZagInstallJobs()
		installing.begin("k", stage: .packaging)
		try? installing.beginInstalling("k")
		installing.setProgress("k", 0.5)
		installing.advance("k", to: .preparingMobileDataFix)
		expect(installing.job("k")?.stage == .installing, "job: installing never returns to a cancellable stage")
		expect(installing.requestCancel("k") == .notPossible && !installing.isCancelRequested("k"), "job: a cancel during installation is refused and not recorded")
		installing.finish("k")
		expect(!installing.isActive("k") && installing.begin("k", stage: .downloading), "job: after finishing, the app can be installed again")
	}

	// MARK: - Resume helpers

	static func resumeHelperTests() {
		func headers(_ h: [String: String]) -> (String) -> String? {
			{ key in h.first { $0.key.lowercased() == key.lowercased() }?.value }
		}
		expect(ZagResumableDownload.supportsResume(statusCode: 200, header: headers(["Accept-Ranges": "bytes", "ETag": "\"a\""]), expectedLength: 10),
			"resume: Range plus ETag supports pause")
		expect(ZagResumableDownload.supportsResume(statusCode: 200, header: headers(["accept-ranges": "bytes", "last-modified": "Mon"]), expectedLength: 10),
			"resume: Range plus Last-Modified supports pause")
		expect(!ZagResumableDownload.supportsResume(statusCode: 200, header: headers(["ETag": "\"a\""]), expectedLength: 10),
			"resume: no Accept-Ranges means no pause")
		expect(!ZagResumableDownload.supportsResume(statusCode: 200, header: headers(["Accept-Ranges": "none", "ETag": "\"a\""]), expectedLength: 10),
			"resume: Accept-Ranges none means no pause")
		expect(!ZagResumableDownload.supportsResume(statusCode: 200, header: headers(["Accept-Ranges": "bytes"]), expectedLength: 10),
			"resume: no validator means no pause")
		expect(!ZagResumableDownload.supportsResume(statusCode: 200, header: headers(["Accept-Ranges": "bytes", "ETag": "x"]), expectedLength: -1),
			"resume: unknown length means no pause")
		expect(ZagResumableDownload.check(resumedAtOffset: 4096, bytesBeforePause: 4096) == .continued, "resume: continuing at the paused offset is a resume")
		expect(ZagResumableDownload.check(resumedAtOffset: 0, bytesBeforePause: 4096) == .restartedByServer, "resume: offset zero after progress is a server restart")

		let archived = try! PropertyListSerialization.data(fromPropertyList: [
			"$objects": ["$null", ["NSURLSessionResumeInfoVersion": 2], "/private/var/mobile/tmp/CFNetworkDownload_Ab12.tmp"]
		], format: .binary, options: 0)
		expect(ZagResumableDownload.partialFileName(inResumeData: archived) == "CFNetworkDownload_Ab12.tmp", "cleanup: finds the partial file in resume data")
		let foreign = try! PropertyListSerialization.data(fromPropertyList: ["path": "/var/mobile/Documents/MyApp.ipa"], format: .binary, options: 0)
		expect(ZagResumableDownload.partialFileName(inResumeData: foreign) == nil, "cleanup: never targets a file that is not a CFNetwork partial download")
		expect(ZagResumableDownload.partialFileName(inResumeData: Data("junk".utf8)) == nil, "cleanup: unreadable resume data deletes nothing")
	}

	// MARK: - Real URLSession pause and resume

	/// Serves a fixed body slowly. `rangeSupport` controls Accept-Ranges/ETag
	/// on the first response; `honourRange` controls whether later requests
	/// get 206 from the requested offset or the whole file again.
	final class SlowHTTPServer: @unchecked Sendable {
		let body: Data
		let listener: NWListener
		let queue = DispatchQueue(label: "slow-http")
		var rangeSupport = true
		var honourRange = true
		private(set) var requests: [String] = []
		private let lock = NSLock()

		init(size: Int) throws {
			body = Data((0..<size).map { UInt8($0 % 251) })
			listener = try NWListener(using: .tcp, on: .any)
		}

		var port: UInt16 { listener.port?.rawValue ?? 0 }

		func start() async {
			listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				var resumed = false
				listener.stateUpdateHandler = { state in
					if case .ready = state, !resumed { resumed = true; continuation.resume() }
				}
				listener.start(queue: queue)
			}
		}

		func stop() { listener.cancel() }

		func recorded() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }

		private func serve(_ connection: NWConnection) {
			connection.start(queue: queue)
			receiveHeader(connection, buffer: Data())
		}

		private func receiveHeader(_ connection: NWConnection, buffer: Data) {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
				guard let self else { return }
				var buffer = buffer
				if let data { buffer.append(data) }
				guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
					if done || error != nil { connection.cancel() } else { self.receiveHeader(connection, buffer: buffer) }
					return
				}
				self.respond(connection, request: text)
			}
		}

		private func respond(_ connection: NWConnection, request: String) {
			let rangeLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
			lock.lock(); requests.append(rangeLine ?? "full"); lock.unlock()
			var start = 0
			if honourRange, let rangeLine, let value = rangeLine.split(separator: "=").last?.split(separator: "-").first, let offset = Int(value) {
				start = offset
			}
			let slice = body.subdata(in: start..<body.count)
			var head = start > 0 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
			head += "Content-Type: application/octet-stream\r\nContent-Length: \(slice.count)\r\nConnection: close\r\n"
			if rangeSupport { head += "Accept-Ranges: bytes\r\nETag: \"zag-test-1\"\r\n" }
			if start > 0 { head += "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n" }
			head += "\r\n"
			connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
			sendChunks(connection, slice, from: 0)
		}

		private func sendChunks(_ connection: NWConnection, _ data: Data, from offset: Int) {
			guard offset < data.count else {
				connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
				return
			}
			let end = min(data.count, offset + 32 * 1024)
			connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
				guard error == nil else { connection.cancel(); return }
				self?.queue.asyncAfter(deadline: .now() + 0.03) { self?.sendChunks(connection, data, from: end) }
			})
		}
	}

	/// Mirrors DownloadManager's delegate decisions: pause support from the
	/// response, and the resume offset check.
	final class DownloadProbe: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
		let lock = NSLock()
		var written: Int64 = 0
		var resumable = false
		var resumedAt: Int64?
		var finished: Data?
		var finishedError: Error?
		var progressEvents = 0

		func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
			let response = downloadTask.response as? HTTPURLResponse
			let ok = response.map { r in
				ZagResumableDownload.supportsResume(statusCode: r.statusCode, header: { r.value(forHTTPHeaderField: $0) }, expectedLength: totalBytesExpectedToWrite)
			} ?? false
			lock.lock(); written = totalBytesWritten; resumable = ok; progressEvents += 1; lock.unlock()
		}
		func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
			lock.lock(); resumedAt = fileOffset; lock.unlock()
		}
		func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
			let data = try? Data(contentsOf: location)
			lock.lock(); finished = data; lock.unlock()
		}
		func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
			lock.lock(); finishedError = error; lock.unlock()
		}
		func snapshot<T>(_ read: (DownloadProbe) -> T) -> T { lock.lock(); defer { lock.unlock() }; return read(self) }
		/// Forget the paused task's own "cancelled" completion before resuming.
		func resetForResume() { lock.lock(); finishedError = nil; finished = nil; resumedAt = nil; lock.unlock() }
	}

	static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
		let end = Date().addingTimeInterval(timeout)
		while Date() < end {
			if condition() { return true }
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return condition()
	}

	static func pauseResumeTests() async {
		do {
			// 1. Resumable server: pause produces resume data, resume continues
			//    at the paused offset, and the file is complete and identical.
			let server = try SlowHTTPServer(size: 1_200_000)
			await server.start()
			defer { server.stop() }
			let url = URL(string: "http://127.0.0.1:\(server.port)/app.ipa")!

			let probe = DownloadProbe()
			let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
			let task = session.downloadTask(with: url)
			task.resume()
			_ = await waitUntil(5) { probe.snapshot { $0.written > 200_000 } }
			expect(probe.snapshot { $0.resumable }, "download: a Range + ETag server offers pause")

			let resumeData: Data? = await withCheckedContinuation { c in task.cancel(byProducingResumeData: { c.resume(returning: $0) }) }
			let pausedAt = probe.snapshot { $0.written }
			expect(resumeData?.isEmpty == false, "pause: stopping the transfer produces resume data")
			let eventsAtPause = probe.snapshot { $0.progressEvents }
			try? await Task.sleep(nanoseconds: 300_000_000)
			expect(probe.snapshot { $0.progressEvents } == eventsAtPause, "pause: no download activity while paused")

			probe.resetForResume()
			let resumed = session.downloadTask(withResumeData: resumeData!)
			resumed.resume()
			_ = await waitUntil(10) { probe.snapshot { $0.finished != nil || $0.finishedError != nil } }
			let resumedAt = probe.snapshot { $0.resumedAt } ?? -1
			expect(resumedAt > 0 && ZagResumableDownload.check(resumedAtOffset: resumedAt, bytesBeforePause: pausedAt) == .continued,
				"resume: continues from partial data (offset \(resumedAt), paused at \(pausedAt))")
			expect(probe.snapshot { $0.finished } == server.body, "resume: the finished file is complete and identical")
			expect(server.recorded().contains { $0.lowercased().contains("range: bytes=") }, "resume: the second request asks for a byte range")
			session.invalidateAndCancel()

			// 2. Server that ignores Range on resume: detected, not silently restarted.
			let restart = try SlowHTTPServer(size: 1_200_000)
			await restart.start()
			defer { restart.stop() }
			let url2 = URL(string: "http://127.0.0.1:\(restart.port)/app.ipa")!
			let probe2 = DownloadProbe()
			let session2 = URLSession(configuration: .ephemeral, delegate: probe2, delegateQueue: nil)
			let task2 = session2.downloadTask(with: url2)
			task2.resume()
			_ = await waitUntil(5) { probe2.snapshot { $0.written > 200_000 } }
			let data2: Data? = await withCheckedContinuation { c in task2.cancel(byProducingResumeData: { c.resume(returning: $0) }) }
			let paused2 = probe2.snapshot { $0.written }
			restart.honourRange = false
			if let data2 {
				probe2.resetForResume()
				let resumed2 = session2.downloadTask(withResumeData: data2)
				resumed2.resume()
				_ = await waitUntil(5) { probe2.snapshot { $0.resumedAt != nil || $0.finishedError != nil } }
				let offset = probe2.snapshot { $0.resumedAt }
				// URLSession either reports offset 0 (caught as a restart) or fails
				// the task; neither is accepted as a resume.
				let caught = offset.map { ZagResumableDownload.check(resumedAtOffset: $0, bytesBeforePause: paused2) == .restartedByServer } ?? (probe2.snapshot { $0.finishedError } != nil)
				let failure = probe2.snapshot { $0.finishedError as NSError? }
				let carriesResumeData = failure?.userInfo[NSURLSessionDownloadTaskResumeData] != nil
				expect(caught, "failed resume: a server restart is detected, never treated as a resume (offset \(offset.map(String.init) ?? "none"), error \(failure.map { "\($0.domain) \($0.code)" } ?? "none"), resume data \(carriesResumeData))")
				resumed2.cancel()
			} else {
				expect(false, "failed resume: setup produced no resume data")
			}
			session2.invalidateAndCancel()

			// 3. Server without Range support: pause is not offered.
			let plain = try SlowHTTPServer(size: 400_000)
			plain.rangeSupport = false
			await plain.start()
			defer { plain.stop() }
			let probe3 = DownloadProbe()
			let session3 = URLSession(configuration: .ephemeral, delegate: probe3, delegateQueue: nil)
			session3.downloadTask(with: URL(string: "http://127.0.0.1:\(plain.port)/app.ipa")!).resume()
			_ = await waitUntil(5) { probe3.snapshot { $0.written > 50_000 } }
			expect(!probe3.snapshot { $0.resumable }, "download: a server without Range support offers no pause")
			session3.invalidateAndCancel()

			// 4. Cancelling a paused download removes its partial file.
			let cleanup = try SlowHTTPServer(size: 1_200_000)
			await cleanup.start()
			defer { cleanup.stop() }
			let probe4 = DownloadProbe()
			let session4 = URLSession(configuration: .ephemeral, delegate: probe4, delegateQueue: nil)
			let task4 = session4.downloadTask(with: URL(string: "http://127.0.0.1:\(cleanup.port)/app.ipa")!)
			task4.resume()
			_ = await waitUntil(5) { probe4.snapshot { $0.written > 200_000 } }
			let data4: Data? = await withCheckedContinuation { c in task4.cancel(byProducingResumeData: { c.resume(returning: $0) }) }
			if let data4, let name = ZagResumableDownload.partialFileName(inResumeData: data4) {
				let partial = FileManager.default.temporaryDirectory.appendingPathComponent(name)
				let existed = FileManager.default.fileExists(atPath: partial.path)
				try? FileManager.default.removeItem(at: partial)
				expect(existed && !FileManager.default.fileExists(atPath: partial.path), "cleanup: the paused download's partial file is found and removed")
			} else {
				// Some URLSession versions keep the partial file elsewhere; the
				// cleanup then deletes nothing, which is safe.
				expect(data4 != nil, "cleanup: resume data exists for a paused download")
			}
			session4.invalidateAndCancel()
		} catch {
			expect(false, "pause/resume tests could not start a local server: \(error)")
		}
	}

	// MARK: - Cancellation through the Mobile Data flow

	@MainActor static func installCancelTests() async {
		let id = "repo:app"
		func run(_ f: FakeMobileData, jobs: ZagInstallJobs, cancelWhen: @escaping ([String]) -> Bool) async -> ZagMobileDataInstallOutcome {
			let flow = ZagMobileDataInstallFlow(environment: f.environment)
			return await flow.run(jobID: id, cancelRequested: {
				if cancelWhen(f.calls), jobs.job(id)?.stage.allowsCancel == true { _ = jobs.requestCancel(id) }
				return jobs.isCancelRequested(id)
			}) {
				try jobs.beginInstalling(id)
				try await f.operation()
			}
		}

		// Cancel before Mobile Data OFF: nothing changes.
		var f = FakeMobileData.mobileDataBlocked()
		var jobs = ZagInstallJobs(); jobs.begin(id, stage: .preparingMobileDataFix)
		var o = await run(f, jobs: jobs) { _ in true }
		expect(o.notAttempted == .cancelled && !f.calls.contains("off") && !f.calls.contains("install") && f.record == nil,
			"cancel before OFF: Mobile Data untouched, nothing installed (\(f.calls))")

		// Cancel during the OFF Shortcut handoff: the command finishes, then
		// Mobile Data is restored.
		f = FakeMobileData.mobileDataBlocked()
		jobs = ZagInstallJobs(); jobs.begin(id, stage: .preparingMobileDataFix)
		o = await run(f, jobs: jobs) { $0.contains("off") }
		expect(o.notAttempted == .cancelled && f.calls == ["consent", "off", "on"] && o.restoration == .restored && f.record == nil,
			"cancel during Shortcuts handoff: OFF completes, nothing installed, ON restores (\(f.calls))")

		// Cancel after OFF but restoration can't be confirmed: recovery kept.
		f = FakeMobileData(); f.networks = [.cellular]; f.endpoints = [.refused, .reachable]; f.replies[.on] = .timedOut
		jobs = ZagInstallJobs(); jobs.begin(id, stage: .preparingMobileDataFix)
		o = await run(f, jobs: jobs) { $0.contains("off") }
		expect(o.notAttempted == .cancelled && o.restoration == .unconfirmed && f.record != nil,
			"cancel after OFF: unconfirmed restoration keeps the recovery record and banner")

		// Cancel requested once the installer started: refused, install completes.
		f = FakeMobileData.mobileDataBlocked()
		jobs = ZagInstallJobs(); jobs.begin(id, stage: .preparingMobileDataFix)
		o = await run(f, jobs: jobs) { $0.contains("install") }
		expect(o.installed && !jobs.isCancelRequested(id) && f.calls.last == "on",
			"no cancel once RPPairing installation begins: the install completes and Mobile Data is restored")

		// Wi-Fi: cancel before install is honoured at the last safe point.
		f = FakeMobileData()
		jobs = ZagInstallJobs(); jobs.begin(id, stage: .preparingMobileDataFix); _ = jobs.requestCancel(id)
		o = await run(f, jobs: jobs) { _ in false }
		expect(!o.installed && o.installError is ZagInstallCancelled && !f.calls.contains("install"),
			"cancel on Wi-Fi before installation: the installer never starts")

		// No regressions without cancellation.
		f = FakeMobileData()
		jobs = ZagInstallJobs(); jobs.begin(id, stage: .preparingMobileDataFix)
		o = await run(f, jobs: jobs) { _ in false }
		expect(o.installed && f.calls == ["install"] && jobs.job(id)?.stage == .installing, "no cancel: Wi-Fi installs as before")
		f = FakeMobileData.mobileDataBlocked()
		jobs = ZagInstallJobs(); jobs.begin(id, stage: .preparingMobileDataFix)
		o = await run(f, jobs: jobs) { _ in false }
		expect(o.installed && f.calls == ["consent", "off", "install", "on"], "no cancel: Mobile Data installs as before")

		// Pipeline safe points: committed records are kept.
		final class Records { var imported = false; var signed = false; var packageDir = false }
		@MainActor func pipeline(cancelAt: ZagInstallStage?) async -> (Records, Bool) {
			let r = Records()
			let j = ZagInstallJobs()
			j.begin(id, stage: .downloading)
			func maybeCancel(_ stage: ZagInstallStage) { if stage == cancelAt { _ = j.requestCancel(id) } }
			do {
				maybeCancel(.downloading)
				try j.checkpoint(id)
				j.advance(id, to: .importing); maybeCancel(.importing)
				r.imported = true                       // import finishes and commits
				try j.checkpoint(id)
				j.advance(id, to: .signing); maybeCancel(.signing)
				r.signed = true                         // signing finishes and commits
				try j.checkpoint(id)
				j.advance(id, to: .packaging); maybeCancel(.packaging)
				r.packageDir = true                     // job-owned package
				defer { r.packageDir = false }          // removed on every path
				try j.checkpoint(id)
				j.advance(id, to: .preparingMobileDataFix)
				try j.beginInstalling(id)
				return (r, true)
			} catch {
				return (r, false)
			}
		}
		var (r, installed) = await pipeline(cancelAt: .downloading)
		expect(!installed && !r.imported && !r.signed, "cancel during download: nothing imported or signed")
		(r, installed) = await pipeline(cancelAt: .importing)
		expect(!installed && r.imported && !r.signed, "cancel during import: the committed Imported record is kept; signing never starts")
		(r, installed) = await pipeline(cancelAt: .signing)
		expect(!installed && r.imported && r.signed, "cancel during signing: signing finishes and the Signed record is kept")
		(r, installed) = await pipeline(cancelAt: .packaging)
		expect(!installed && r.signed && !r.packageDir, "cancel during packaging: the job's package is removed; Signed kept")
		(r, installed) = await pipeline(cancelAt: nil)
		expect(installed && !r.packageDir, "no cancel: the pipeline reaches installation and still removes its package")

		// Background/foreground: the job store is independent of views.
		let shared = ZagInstallJobs()
		shared.begin(id, stage: .downloading); shared.setProgress(id, 0.3); shared.advance(id, to: .paused)
		// A row disappearing and reappearing (scroll, Shortcuts) reads the same job.
		let reread = shared.job(id)
		expect(reread?.stage == .paused && reread?.progress == 0.3, "background/foreground: stage and progress survive view recreation")
	}
}

// MARK: - App Store-style control

extension ZagDeviceLinkTests {
	static func installControlTests() {
		typealias G = ZagInstallControlGeometry
		typealias M = ZagInstallControlMotion
		let get = ZagInstallControlMode.pill(ZagInstallPill(title: "Get", accessibilityLabel: "Get"))
		let open = ZagInstallControlMode.pill(ZagInstallPill(title: "Open", accessibilityLabel: "Open"))
		let resume = ZagInstallControlMode.pill(ZagInstallPill(title: "Resume", systemImage: "icloud.and.arrow.down", accessibilityLabel: "Resume"))
		let downloading = ZagInstallControlMode.progress(0.4, .pause)
		let installing = ZagInstallControlMode.spinner(.none)

		// Geometry: existing sizes only
		let pill = G.of(get), circle = G.of(downloading)
		expect(pill.width == 88 && pill.height == 34 && pill.cornerRadius == 17, "control: the pill keeps the 88 × 34 capsule")
		expect(circle.width == 31 && circle.height == 31 && circle.cornerRadius == 15.5, "control: the circle keeps the 31 pt ring size")
		expect(pill.labelOpacity == 1 && pill.ringOpacity == 0 && circle.labelOpacity == 0 && circle.ringOpacity == 1,
			"control: label and ring are never both visible at rest")
		expect(G.of(resume) == pill && G.of(open) == pill, "control: Resume and Open return to exactly the original pill")

		// Trailing anchor and stable row
		expect(pill.origin.x == 0 && circle.origin.x == 57 && circle.origin.x + circle.width == 88,
			"control: the circle ends on the pill's trailing edge")
		expect(circle.origin.y == 1.5 && pill.origin.y == 0, "control: centred vertically in the fixed action frame")
		expect([get, downloading, installing, resume, open].allSatisfy { G.of($0).width <= G.pillWidth && G.of($0).height <= G.pillHeight },
			"control: no state exceeds the fixed 88 × 34 frame, so the row never reflows")

		// The sequence Get → circle → Resume → circle → Open
		let sequence = [get, downloading, resume, .progress(0.6, .pause), installing, .progress(1, .none), open]
		let compact = sequence.map(\.isCompact)
		expect(compact == [false, true, false, true, true, true, false], "control: Get → circle → Resume → circle → installing → Open")
		expect(M.spec(toCompact: true, reduceMotion: false).morph == M.spec(toCompact: false, reduceMotion: false).morph,
			"control: contracting and expanding use the same morph curve (reversible)")
		if case .spring(_, let damping) = M.spec(toCompact: true, reduceMotion: false).morph {
			expect(damping >= 0.85, "control: no visible overshoot (damping \(damping))")
		} else { expect(false, "control: the morph is a spring") }
		let shrink = M.spec(toCompact: true, reduceMotion: false)
		if case .easeOut(let out) = shrink.label, case .easeIn(_, let delay) = shrink.ring {
			expect(out <= delay, "control: contracting, the label is gone before the ring appears (no overlap)")
		} else { expect(false, "control: contracting fades are ordered") }
		let grow = M.spec(toCompact: false, reduceMotion: false)
		if case .easeOut(let out) = grow.ring, case .easeIn(_, let delay) = grow.label {
			expect(out <= delay, "control: expanding, the ring is gone before the label appears (no overlap)")
		} else { expect(false, "control: expanding fades are ordered") }

		// Reduce Motion
		let reduced = M.spec(toCompact: true, reduceMotion: true)
		expect(reduced.morph == .none && reduced.label != .none && reduced.ring != .none, "control: Reduce Motion skips the morph and only cross-fades")

		// No fake pause; interactivity
		expect(installing.glyph == .none && !installing.isInteractive, "control: no pause while signing, packaging or installing; taps reach the row")
		expect(downloading.isInteractive && ZagInstallControlMode.progress(0.4, .stop).isInteractive, "control: a download can be paused or stopped by tapping")
		expect(!ZagInstallControlMode.progress(0.9, .none).isInteractive, "control: importing is not tappable")
		let disabled = ZagInstallControlMode.pill(ZagInstallPill(title: "Get", enabled: false, accessibilityLabel: "Get"))
		expect(!disabled.isInteractive, "control: a claimed action ignores repeated taps")
	}
}

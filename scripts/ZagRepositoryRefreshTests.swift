import Foundation

// Host tests for repository refresh and update inputs.
//
// Compiled with the production sources:
//   Feather/Utilities/ZagInstalledInventory.swift
//   Feather/Utilities/ZagRepositoryRefreshRecord.swift
//   NimbleKit/Sources/NimbleJSON/NBFetchService.swift
// Network responses are served by a URLProtocol stub; nothing leaves the Mac.

private var passed = 0
private var failed = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
	if condition() {
		passed += 1
		print("PASS  \(name)")
	} else {
		failed += 1
		print("FAIL  \(name)")
	}
}

// MARK: - Stub network

private struct StubResponse {
	var status: Int = 200
	var body: Data = Data()
	var headers: [String: String] = [:]
	var error: URLError.Code? = nil
}

private final class StubProtocol: URLProtocol {
	static var queue: [String: [StubResponse]] = [:]
	static var lastRequestHeaders: [String: String] = [:]
	static let lock = NSLock()

	static func enqueue(_ url: URL, _ response: StubResponse) {
		lock.lock(); defer { lock.unlock() }
		queue[url.absoluteString, default: []].append(response)
	}

	override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "zag-test.invalid" }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let key = request.url!.absoluteString
		Self.lock.lock()
		Self.lastRequestHeaders = request.allHTTPHeaderFields ?? [:]
		let response = Self.queue[key]?.isEmpty == false ? Self.queue[key]!.removeFirst() : StubResponse(status: 404)
		Self.lock.unlock()
		if let code = response.error {
			client?.urlProtocol(self, didFailWithError: URLError(code))
			return
		}
		let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
		client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
		if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

private struct Repo: Codable, Equatable {
	struct App: Codable, Equatable {
		let bundleIdentifier: String
		let version: String
	}
	let name: String
	let apps: [App]
}

private func repoData(_ name: String, apps: [(String, String)]) -> Data {
	try! JSONEncoder().encode(Repo(name: name, apps: apps.map { Repo.App(bundleIdentifier: $0.0, version: $0.1) }))
}

private func fetch(_ service: NBFetchService, _ url: URL) -> Result<Repo, Error> {
	let done = DispatchSemaphore(value: 0)
	var result: Result<Repo, Error>!
	service.fetch(from: url) { (r: Result<Repo, Error>) in
		result = r
		done.signal()
	}
	_ = done.wait(timeout: .now() + 20)
	return result
}

private func status(_ url: URL) -> String? { NBRepositoryFetchDiagnostics.metric(for: url.absoluteString)?.status }

// MARK: - Installed inventory

private func entry(_ id: String, _ version: String) -> ZagInventoryEntry {
	ZagInventoryEntry(bundleID: id, version: version, build: "", name: id)
}

/// Thirteen installed apps; Zag Store holds Signed copies of six of them.
private let deviceApps: [String: ZagInventoryEntry] = Dictionary(uniqueKeysWithValues: (1...13).map {
	("com.example.app\($0)", entry("com.example.app\($0)", "1.0"))
})

/// Mirrors UpdateManager: device apps when the resolution is device
/// inventory, otherwise the Signed records only.
private func installedIdentities(_ r: ZagInventoryResolution, signed: Set<String>) -> Set<String> {
	r.isDeviceInventory ? Set(r.apps.keys) : signed
}

private func inventoryTests(home: URL) {
	let storeURL = home.appendingPathComponent("inventory.json")
	let signed = Set((1...6).map { "com.example.app\($0)" })
	let readAt = Date(timeIntervalSince1970: 1_800_000_000)

	// Wi-Fi cold start: the live read succeeds and is saved.
	let store = ZagInventorySnapshotStore(fileURL: storeURL)
	store.save(ZagInventorySnapshot(readAt: readAt, apps: deviceApps))
	let wifiCold = ZagInventoryResolver.resolve(liveLoaded: true, live: deviceApps, cached: store.load(), pairingFilePresent: true)

	// Wi-Fi manual refresh: live again.
	let wifiManual = ZagInventoryResolver.resolve(liveLoaded: true, live: deviceApps, cached: store.load(), pairingFilePresent: true)

	// Mobile Data manual refresh: the iPhone refuses RPPairing, the read fails.
	let mobileManual = ZagInventoryResolver.resolve(liveLoaded: false, live: [:], cached: store.load(), pairingFilePresent: true)

	// Mobile Data cold start: new process, nothing read yet, list loaded from disk.
	let relaunched = ZagInventorySnapshotStore(fileURL: storeURL)
	let mobileCold = ZagInventoryResolver.resolve(liveLoaded: false, live: [:], cached: relaunched.load(), pairingFilePresent: true)

	let all = [wifiCold, wifiManual, mobileCold, mobileManual]
	expect(all.allSatisfy { $0.isDeviceInventory }, "inventory: all four entry points use the iPhone's installed apps")
	expect(Set(all.map { installedIdentities($0, signed: signed) }).count == 1,
		"inventory: Wi-Fi/Mobile Data × cold start/manual refresh give the identical installed set")
	expect(installedIdentities(mobileManual, signed: signed).count == 13,
		"inventory: Mobile Data refresh keeps all 13 installed apps (reported bug: fell to 6 Signed apps)")

	// The rule before this fix: device inventory only when the live read is loaded.
	let before = { (liveLoaded: Bool) -> Set<String> in liveLoaded ? Set(deviceApps.keys) : signed }
	expect(before(false).count == 6 && before(true).count == 13,
		"inventory: reproduces the reported discrepancy with the previous rule (13 on Wi-Fi, 6 on Mobile Data)")

	if case .cached(let at) = mobileManual.source {
		expect(at == readAt, "inventory: diagnostics say the kept list's read time")
	} else {
		expect(false, "inventory: Mobile Data refresh is labelled as the kept device list")
	}
	expect(wifiCold.source == .live, "inventory: a live read is labelled live")

	// Nothing to fall back to.
	let unpaired = ZagInventoryResolver.resolve(liveLoaded: false, live: [:], cached: store.load(), pairingFilePresent: false)
	expect(!unpaired.isDeviceInventory, "inventory: without pairing the Signed fallback stays, as before")
	let neverRead = ZagInventoryResolver.resolve(liveLoaded: false, live: [:], cached: nil, pairingFilePresent: true)
	if case .signedFallback(let reason) = neverRead.source {
		expect(reason.contains("none saved"), "inventory: never-read device reports why it uses the Signed fallback")
	} else {
		expect(false, "inventory: never-read device uses the Signed fallback")
	}

	// A failed read never erases the kept list; an empty list is never saved.
	store.save(ZagInventorySnapshot(readAt: Date(), apps: [:]))
	expect(ZagInventorySnapshotStore(fileURL: storeURL).load()?.apps.count == 13,
		"inventory: an empty read never replaces the last complete list")

	// A legitimate removal confirmed by a successful read is kept.
	var removed = deviceApps
	removed.removeValue(forKey: "com.example.app13")
	store.save(ZagInventorySnapshot(readAt: Date(), apps: removed))
	let afterRemoval = ZagInventoryResolver.resolve(liveLoaded: false, live: [:], cached: ZagInventorySnapshotStore(fileURL: storeURL).load(), pairingFilePresent: true)
	expect(afterRemoval.apps.count == 12 && afterRemoval.apps["com.example.app13"] == nil,
		"inventory: an app removed in a successful read stays removed")

	// A live read always wins over the kept list.
	let newer = ZagInventoryResolver.resolve(liveLoaded: true, live: [ "com.example.app1": entry("com.example.app1", "2.0") ], cached: store.load(), pairingFilePresent: true)
	expect(newer.apps["com.example.app1"]?.version == "2.0" && newer.apps.count == 1, "inventory: a live read replaces the kept list")
}

// MARK: - Repository fetch

private func fetchTests() {
	let id = UUID().uuidString
	let url = URL(string: "https://zag-test.invalid/\(id)/repo.json")!
	let other = URL(string: "https://zag-test.invalid/\(id)/other.json")!
	let large = URL(string: "https://zag-test.invalid/\(id)/large.json")!
	defer {
		let cleanup = NBFetchService()
		for u in [url, other, large] { cleanup.removeCachedRepository(for: u) }
	}

	let v1 = repoData("Repo", apps: [("a", "1.0"), ("b", "1.0"), ("c", "1.0")])
	let v2 = repoData("Repo", apps: [("a", "2.0"), ("b", "1.0")])

	// Fresh download is committed and saved.
	StubProtocol.enqueue(url, StubResponse(status: 200, body: v1, headers: ["ETag": "\"v1\"", "Content-Length": "\(v1.count)"]))
	let first = fetch(NBFetchService(), url)
	expect((try? first.get().apps.count) == 3 && status(url) == "network/200", "fetch: valid 200 is parsed and committed")
	expect(NBRepositoryFetchDiagnostics.metric(for: url.absoluteString)?.expectedBytes == Int64(v1.count),
		"fetch: diagnostics record bytes expected")

	// Every failure falls back to the last valid copy (fresh service = cold start, no memory cache).
	let failures: [(String, StubResponse)] = [
		("HTTP 500", StubResponse(status: 500)),
		("timeout", StubResponse(error: .timedOut)),
		("connection lost", StubResponse(error: .networkConnectionLost)),
		("parse failure", StubResponse(status: 200, body: Data("{\"name\": \"Repo\", \"apps\": [".utf8))),
		("partial download", StubResponse(status: 200, body: v2.prefix(20), headers: ["Content-Length": "\(v2.count)"])),
	]
	for (name, response) in failures {
		StubProtocol.enqueue(url, response)
		let result = fetch(NBFetchService(), url)
		expect((try? result.get()) == (try? first.get()) && status(url) == "disk-cache/fallback",
			"fetch: \(name) keeps the last valid repository (3 apps), never a partial one")
		expect(NBRepositoryFetchDiagnostics.metric(for: url.absoluteString)?.error?.isEmpty == false,
			"fetch: \(name) is reported with its error")
	}
	expect(NBRepositoryFetchDiagnostics.metric(for: url.absoluteString)?.error?.contains("Incomplete download") == true,
		"fetch: a body shorter than Content-Length is reported as an incomplete download")

	// Same with the in-memory copy (manual refresh in a running app).
	let running = NBFetchService()
	StubProtocol.enqueue(url, StubResponse(status: 200, body: v1, headers: ["ETag": "\"v1\""]))
	_ = fetch(running, url)
	StubProtocol.enqueue(url, StubResponse(error: .timedOut))
	expect((try? fetch(running, url).get().apps.count) == 3 && status(url) == "decoded-cache/fallback",
		"fetch: a running app's refresh failure keeps its in-memory copy and reports it")

	// 304 reuses the saved copy and sends the validator.
	StubProtocol.enqueue(url, StubResponse(status: 304))
	let notModified = fetch(NBFetchService(), url)
	expect((try? notModified.get().apps.count) == 3 && StubProtocol.lastRequestHeaders["If-None-Match"] == "\"v1\"",
		"fetch: HTTP 304 reuses the saved copy after a conditional request")
	expect(status(url)?.contains("304") == true, "fetch: 304 is recorded as unchanged")

	// A valid snapshot with fewer apps is a legitimate removal and is committed.
	StubProtocol.enqueue(url, StubResponse(status: 200, body: v2, headers: ["ETag": "\"v2\""]))
	expect((try? fetch(NBFetchService(), url).get().apps.count) == 2, "fetch: a valid repository that removed an app is committed")
	StubProtocol.enqueue(url, StubResponse(error: .timedOut))
	expect((try? fetch(NBFetchService(), url).get().apps.count) == 2, "fetch: after that, failures fall back to the new valid copy")

	// No saved copy and a failure: reported missing, nothing invented.
	StubProtocol.enqueue(other, StubResponse(error: .notConnectedToInternet))
	if case .failure = fetch(NBFetchService(), other) {
		expect(status(other) == "failed", "fetch: a first-ever failure is reported as failed")
	} else {
		expect(false, "fetch: a first-ever failure is not reported as success")
	}

	// Large repository.
	let bigApps = (0..<30_000).map { ("com.example.big\($0)", "1.\($0 % 10)") }
	let big = repoData("Big", apps: bigApps)
	StubProtocol.enqueue(large, StubResponse(status: 200, body: big, headers: ["Content-Length": "\(big.count)"]))
	expect((try? fetch(NBFetchService(), large).get().apps.count) == 30_000,
		"fetch: a large repository (\(big.count / 1_048_576) MB, 30,000 apps) is fully parsed")

	// Network type is not an input: identical responses decode identically.
	StubProtocol.enqueue(large, StubResponse(status: 200, body: big))
	StubProtocol.enqueue(large, StubResponse(status: 200, body: big))
	let viaWiFi = try? fetch(NBFetchService(), large).get()
	let viaMobile = try? fetch(NBFetchService(), large).get()
	expect(viaWiFi != nil && viaWiFi == viaMobile, "fetch: identical responses give identical repositories on any network")
}

// MARK: - Refresh records and ordering

private func recordTests() {
	typealias R = ZagRepositoryRefreshRecord
	expect(R.outcome(fetchSucceeded: true, metricStatus: "network/200", error: nil) == .fresh, "record: 200 is fresh")
	expect(R.outcome(fetchSucceeded: true, metricStatus: "disk-cache/304", error: nil) == .notModified, "record: 304 is unchanged")
	expect(R.outcome(fetchSucceeded: true, metricStatus: "decoded-cache/304", error: nil) == .notModified, "record: decoded 304 is unchanged")
	if case .retainedLastGood = R.outcome(fetchSucceeded: true, metricStatus: "disk-cache/fallback", error: "timeout") {
		expect(true, "record: a cache fallback is a failure with the last valid copy retained, not a success")
	} else { expect(false, "record: a cache fallback is a failure with the last valid copy retained, not a success") }
	if case .missing = R.outcome(fetchSucceeded: false, metricStatus: "failed", error: "offline") {
		expect(true, "record: no data is missing")
	} else { expect(false, "record: no data is missing") }

	expect(R.safeIdentifier(URL(string: "https://user:secret@repo.example.com/apps.json?token=abc#x")!) == "https://repo.example.com/apps.json",
		"record: diagnostics never include credentials, query tokens or fragments")

	func record(_ id: String, _ outcome: R.Outcome) -> R {
		R(identifier: id, networkPath: "Mobile Data", startedAt: Date(), finishedAt: Date(), httpStatus: 200, bytes: 10,
		  expectedBytes: 10, downloadSeconds: 0.1, parseSeconds: 0.1, appsBefore: 3, appsAfter: 3, outcome: outcome)
	}
	let oneFailed = ZagRepositoryRefreshSummary(startedAt: Date(), finishedAt: Date(), networkPath: "Mobile Data", configuredCount: 3,
		records: [record("a", .fresh), record("b", .notModified), record("c", .retainedLastGood(reason: "timeout"))])
	expect(oneFailed.isComplete && oneFailed.retainedCount == 1 && oneFailed.freshness.hasPrefix("mixed"),
		"summary: one failing repository keeps its last valid copy and the result is labelled mixed")
	expect(oneFailed.lines().first?.contains("complete with failures") == true, "summary: the failure is reported, not hidden")
	let missing = ZagRepositoryRefreshSummary(startedAt: Date(), finishedAt: Date(), networkPath: "Wi-Fi", configuredCount: 3,
		records: [record("a", .fresh), record("b", .missing(reason: "offline"))])
	expect(!missing.isComplete && missing.missingCount == 2 && missing.lines().first?.contains("INCOMPLETE") == true,
		"summary: a missing or unreported repository marks the refresh incomplete")
	let clean = ZagRepositoryRefreshSummary(startedAt: Date(), finishedAt: Date(), networkPath: "Wi-Fi", configuredCount: 2,
		records: [record("a", .fresh), record("b", .notModified)])
	expect(clean.isComplete && clean.freshness == "fresh", "summary: all current repositories are fresh")

	var ordering = ZagRefreshOrdering()
	let t0 = Date(timeIntervalSince1970: 1000)
	expect(ordering.admit(snapshotStartedAt: t0), "ordering: first refresh publishes")
	expect(ordering.admit(snapshotStartedAt: t0.addingTimeInterval(5)), "ordering: a later refresh publishes")
	expect(!ordering.admit(snapshotStartedAt: t0.addingTimeInterval(2)), "ordering: a slower earlier refresh can't overwrite a newer result")
	expect(ordering.admit(snapshotStartedAt: t0.addingTimeInterval(5)), "ordering: the same snapshot may publish again (inventory arriving later)")
}

@main
enum ZagRepositoryRefreshTests {
	static func main() {
		URLProtocol.registerClass(StubProtocol.self)
		let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zag-refresh-tests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: home) }

		inventoryTests(home: home)
		fetchTests()
		recordTests()
		print("\(passed) passed, \(failed) failed")
		exit(failed == 0 ? 0 : 1)
	}
}

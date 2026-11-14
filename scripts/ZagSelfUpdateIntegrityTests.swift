import Foundation
import CryptoKit
import Security

// Integrity tests for ZagSelfUpdateCoordinator's download-verification path,
// run as a simulator app by scripts/test-zag-self-update-integrity.sh. The
// real coordinator is compiled against ZagSelfUpdateIntegrityStubs.swift;
// every network request is served by StubProtocol, nothing leaves the Mac.
//
// The central property: the bytes the importer extracts must be the bytes
// authenticated by the signed SHA-256. The importer stub mirrors
// AppFileHandler (verify its own working copy, then extract that copy);
// test-zag-self-update-integrity.sh checks the real handler does the same.
//
// Output: PASS is a mandatory check that passed. KNOWN DEFECT is a documented
// integrity defect that still reproduces. FAIL is a regression, a new defect,
// or a known defect that no longer reproduces (update the inventory below in
// the same change as the fix). Any FAIL makes the suite fail.

final class StubProtocol: URLProtocol {
	enum Behaviour {
		case respond(status: Int, body: Data)
		case dropAfter(Data)
		/// Sends the headers and part of the body, then never finishes.
		case stallAfter(Data)
	}
	static var behaviour = Behaviour.respond(status: 404, body: Data())
	static var releaseRequests = 0
	static var unexpectedRequests: [String] = []

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		guard let url = request.url else { return }
		guard url.host == "github.com" else {
			Self.unexpectedRequests.append(url.absoluteString)
			client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
			return
		}
		Self.releaseRequests += 1
		switch Self.behaviour {
		case .respond(let status, let body):
			let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
			                               headerFields: ["Content-Length": String(body.count)])!
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: body)
			client?.urlProtocolDidFinishLoading(self)
		case .dropAfter(let partial):
			let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
			                               headerFields: ["Content-Length": String(partial.count * 2)])!
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: partial)
			client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
		case .stallAfter(let partial):
			let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
			                               headerFields: ["Content-Length": String(partial.count * 2)])!
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: partial)
		}
	}
	override func stopLoading() {}
}

@main
@MainActor
struct ZagSelfUpdateIntegrityTests {
	typealias Coordinator = ZagSelfUpdateCoordinator
	static var failures = 0
	static var passes = 0
	static var defects = 0

	static func pass(_ message: String) { print("PASS: \(message)"); passes += 1 }
	static func fail(_ message: String) { print("FAIL: \(message)"); failures += 1 }
	static func check(_ condition: Bool, _ message: String) { condition ? pass(message) : fail(message) }

	/// Known integrity defects. `present` is true while the defect reproduces.
	/// Empty: the four defects found by the first version of this suite are
	/// fixed and now covered by mandatory checks.
	static let knownDefects: [String: String] = [:]
	static var observedDefects: Set<String> = []
	/// Every digest the importer extracted during the run.
	static var allExtractedDigests: [String] = []

	static func defect(_ name: String, present: Bool, evidence: String) {
		guard let description = knownDefects[name] else { fail("unknown defect name \(name)"); return }
		observedDefects.insert(name)
		if present {
			print("KNOWN DEFECT: \(name): \(description). Evidence: \(evidence)")
			defects += 1
		} else {
			fail("known defect \(name) no longer reproduces; update the known-defect inventory. Evidence: \(evidence)")
		}
	}

	nonisolated static func sha256(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	nonisolated static let authentic = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
	static let identity = [
		"CFBundleIdentifier": "app.zagstore.ios",
		"CFBundleShortVersionString": "1.0.1",
		"CFBundleVersion": "3",
	]
	static func release(
		sha256: String = Self.sha256(authentic),
		url: String = "https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.1-test/ZagStore.ipa",
		bundleIdentifier: String = "app.zagstore.ios"
	) -> Coordinator.Release {
		Coordinator.Release(version: "1.0.1", build: "3", bundleIdentifier: bundleIdentifier,
		                    ipaURL: URL(string: url)!, sha256: sha256,
		                    minimumIOSVersion: "16.4", releaseNotes: "Integrity harness")
	}

	static var destination: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ZagStore/SelfUpdate/verified-release.ipa")
	}

	static func temporaryDownloads() -> Set<String> {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
		return Set(names.filter { $0.hasPrefix("CFNetworkDownload") })
	}

	/// The coordinator's own partial files, next to verified-release.ipa.
	static func partialDownloads() -> Set<String> {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) ?? []
		return Set(names.filter { $0.hasSuffix(".partial") })
	}

	/// Fresh coordinator state, no staged file, no recorded imports.
	static func reset(_ coordinator: Coordinator, serving behaviour: StubProtocol.Behaviour) {
		coordinator.preferencesChanged()
		try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
		for name in temporaryDownloads() {
			try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + name)
		}
		allExtractedDigests += FR.importedDigests
		FR.importAttempts = 0
		FR.importedDigests = []
		FR.importIdentity = identity
		StubProtocol.behaviour = behaviour
		StubProtocol.releaseRequests = 0
	}

	static func errorName(_ body: () async throws -> Void) async -> String? {
		do { try await body(); return nil } catch { return String(describing: error) }
	}

	/// A disposable Ed25519 test key; never trusted in production.
	static let testKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))

	static func testEnvelope(sequence: Int, now: Date) -> Data {
		let iso = ISO8601DateFormatter()
		let payload = """
		{"appId":"app.zagstore.ios","build":"3","channel":"beta","expiresAt":"\(iso.string(from: now.addingTimeInterval(86_400)))",\
		"ipaURL":"https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.1-test/ZagStore.ipa",\
		"minimumIOSVersion":"16.4","publishedAt":"\(iso.string(from: now.addingTimeInterval(-60)))","releaseNotes":"Integrity harness",\
		"schema":2,"sequence":\(sequence),"sha256":"\(sha256(authentic))","version":"1.0.1"}
		"""
		let bytes = Data(payload.utf8)
		let signature = try! testKey.signature(for: Data("ZAG-STORE-UPDATE-V2\n".utf8) + bytes)
		let envelope = """
		{"keyId":"integrity-test-only","payload":"\(bytes.base64EncodedString())","schema":2,"signature":"\(signature.base64EncodedString())"}
		"""
		return Data(envelope.utf8)
	}

	static func main() async {
		setvbuf(stdout, nil, _IOLBF, 0)
		// Keep the coordinator's own automatic checks off the network.
		UserDefaults.standard.set(false, forKey: Coordinator.automaticChecksKey)
		UserDefaults.standard.set(false, forKey: Coordinator.automaticWiFiDownloadKey)
		URLProtocol.registerClass(StubProtocol.self)
		let coordinator = Coordinator.shared
		let authenticSHA = sha256(authentic)
		var replacement = authentic
		replacement[100] ^= 0xFF

		// 1. Normal path: the staged file and the imported bytes are authentic.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		do {
			let staged = try await coordinator.prepare(release())
			check(staged == destination && coordinator.preparedIPA == destination,
			      "verified download is staged at verified-release.ipa")
			check(sha256(try Data(contentsOf: staged)) == authenticSHA, "staged bytes match the signed SHA-256")
			_ = try await coordinator.importPreparedRelease(release())
			check(FR.importedDigests == [authenticSHA], "importer receives exactly the authenticated bytes")
		} catch {
			fail("normal prepare and import failed: \(error)")
		}

		// 2. The UI path (prepareSignedUpdate) hands the authenticated bytes to
		//    the importer; the signing stub stops it after import.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		let signedPath = await errorName { _ = try await coordinator.prepareSignedUpdate(release(), certificate: CertificatePair()) }
		check(signedPath?.contains("StopAfterImport") == true && FR.importedDigests == [authenticSHA],
		      "prepareSignedUpdate imports exactly the authenticated bytes")

		// 3. An upper-case signed digest is accepted.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		check(await errorName { _ = try await coordinator.prepare(release(sha256: authenticSHA.uppercased())) } == nil,
		      "upper-case signed SHA-256 is accepted")

		// 4-7. Rejected downloads stage nothing and import nothing.
		let rejected: [(String, StubProtocol.Behaviour, String)] = [
			("one changed byte", .respond(status: 200, body: replacement), "checksumMismatch"),
			("truncated body delivered as complete", .respond(status: 200, body: authentic.prefix(40_000)), "checksumMismatch"),
			("HTTP 500 carrying the authentic body", .respond(status: 500, body: authentic), "invalidRelease"),
			("connection dropped mid-download", .dropAfter(authentic.prefix(20_000)), ""),
		]
		for (label, behaviour, expected) in rejected {
			reset(coordinator, serving: behaviour)
			let error = await errorName { _ = try await coordinator.prepare(release()) }
			check(error != nil && (expected.isEmpty || error!.contains(expected)),
			      "\(label) is rejected (\(error ?? "accepted"))")
			check(!FileManager.default.fileExists(atPath: destination.path) && coordinator.preparedIPA == nil,
			      "\(label) stages no file")
			let staleImport = await errorName { _ = try await coordinator.importPreparedRelease(release()) }
			check(staleImport != nil && FR.importedDigests.isEmpty, "\(label) leaves nothing to import")
			let leftover = temporaryDownloads()
			check(leftover.isEmpty, "\(label) leaves no temporary download (\(leftover.sorted()))")
			let partials = partialDownloads()
			check(partials.isEmpty, "\(label) leaves no partial file (\(partials.sorted()))")
		}

		// Cancelled mid-download: nothing staged, nothing left, nothing to import.
		reset(coordinator, serving: .stallAfter(authentic.prefix(20_000)))
		let download = Task { try await coordinator.prepare(release()) }
		var waited = 0
		while StubProtocol.releaseRequests == 0 && waited < 100 {
			try? await Task.sleep(nanoseconds: 20_000_000); waited += 1
		}
		try? await Task.sleep(nanoseconds: 200_000_000)
		download.cancel()
		let cancelled: String?
		do { _ = try await download.value; cancelled = nil } catch { cancelled = String(describing: error) }
		check(cancelled != nil, "cancelled download is not accepted (\(cancelled ?? "accepted"))")
		check(!FileManager.default.fileExists(atPath: destination.path) && coordinator.preparedIPA == nil,
		      "cancelled download stages no file")
		check(partialDownloads().isEmpty && temporaryDownloads().isEmpty,
		      "cancelled download leaves no partial or temporary file")
		let afterCancel = await errorName { _ = try await coordinator.importPreparedRelease(release()) }
		check(afterCancel?.contains("invalidRelease") == true && FR.importAttempts == 0,
		      "after a cancelled download import is refused without reaching the importer")

		// A large package streams through in chunks and verifies.
		let large = Data((0..<(64 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 16)) })
		let largeSHA = sha256(large)
		reset(coordinator, serving: .respond(status: 200, body: large))
		let started = Date()
		let largeResult = await errorName { _ = try await coordinator.prepare(release(sha256: largeSHA)) }
		let seconds = Date().timeIntervalSince(started)
		check(largeResult == nil && (try? ZagPackageIntegrity.sha256(of: destination)) == largeSHA,
		      "a 64 MiB package streams, verifies and stages intact (\(String(format: "%.1f", seconds)) s)")
		check(partialDownloads().isEmpty, "a verified download leaves no partial file")

		// 8. Insecure scheme and wrong identity are refused before any request.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		let insecure = await errorName {
			_ = try await coordinator.prepare(release(url: "http://github.com/zagorskey/zag-store-releases/releases/download/v1.0.1-test/ZagStore.ipa"))
		}
		check(insecure?.contains("insecureDownload") == true && StubProtocol.releaseRequests == 0,
		      "http:// IPA URL is refused before any request")
		let foreign = await errorName { _ = try await coordinator.prepare(release(bundleIdentifier: "com.example.other")) }
		check(foreign?.contains("incompatibleBundleIdentifier") == true && StubProtocol.releaseRequests == 0,
		      "foreign bundle identifier is refused before any request")

		// 9. Deleted after verification: import refuses, importer not called.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		_ = await errorName { _ = try await coordinator.prepare(release()) }
		try? FileManager.default.removeItem(at: destination)
		let deleted = await errorName { _ = try await coordinator.importPreparedRelease(release()) }
		check(deleted?.contains("invalidRelease") == true && FR.importedDigests.isEmpty,
		      "verified file deleted before import is refused")

		// 10. Replaced after verification, before import. Same app identity,
		//     different bytes: the realistic substitution.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		_ = await errorName { _ = try await coordinator.prepare(release()) }
		try? replacement.write(to: destination)
		let replaced = await errorName { _ = try await coordinator.importPreparedRelease(release()) }
		check(replaced?.contains("checksumMismatch") == true && FR.importAttempts == 1 && FR.importedDigests.isEmpty,
		      "file replaced after verification is rejected by the importer before extraction (\(replaced ?? "imported"))")

		// 11. A failed retry after an earlier success discards the earlier file.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		_ = await errorName { _ = try await coordinator.prepare(release()) }
		StubProtocol.behaviour = .respond(status: 200, body: replacement)
		let retry = await errorName { _ = try await coordinator.prepare(release()) }
		check(retry?.contains("checksumMismatch") == true, "corrupted retry is rejected")
		check(coordinator.preparedIPA == nil && !FileManager.default.fileExists(atPath: destination.path),
		      "a failed retry leaves no prepared file behind")
		// Even if a file appears at the old location, nothing points at it.
		try? replacement.write(to: destination)
		let stale = await errorName { _ = try await coordinator.importPreparedRelease(release()) }
		check(stale?.contains("invalidRelease") == true && FR.importAttempts == 0,
		      "after a failed retry import is refused without reaching the importer (\(stale ?? "imported"))")

		// An authentic file whose app is another version still fails the
		// identity check after import.
		reset(coordinator, serving: .respond(status: 200, body: authentic))
		_ = await errorName { _ = try await coordinator.prepare(release()) }
		FR.importIdentity = identity.merging(["CFBundleShortVersionString": "1.0.0"]) { $1 }
		let otherRelease = await errorName { _ = try await coordinator.importPreparedRelease(release()) }
		check(otherRelease?.contains("incompatibleBundleIdentifier") == true,
		      "imported app of another version is refused by the identity check (\(otherRelease ?? "accepted"))")

		// 12. The unsigned local-candidate paths (prepareLocalIPA and
		//     installSelectedLocalCandidate) are removed; the runner checks the
		//     coordinator source no longer contains them.

		// 13. Rollback state: no download outcome changes accepted metadata.
		let service = "app.zagstore.ios.integrity-harness.\(UUID().uuidString)"
		let store = ZagUpdateRollbackStore(service: service)
		defer {
			_ = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
		}
		do {
			let now = Date()
			let keys = ["integrity-test-only": testKey.publicKey.rawRepresentation]
			_ = try await ZagUpdateVerifiedPipeline.accept(envelope: testEnvelope(sequence: 4, now: now), channel: "beta",
			                                               trustedKeys: keys, store: store, now: now)
			for (_, behaviour, _) in rejected {
				reset(coordinator, serving: behaviour)
				_ = await errorName { _ = try await coordinator.prepare(release()) }
			}
			reset(coordinator, serving: .respond(status: 200, body: authentic))
			_ = await errorName { _ = try await coordinator.prepare(release()) }
			check(try await store.highestAccepted(channel: "beta") == 4,
			      "downloads, failed or verified, leave the accepted sequence unchanged")
			let replay = await errorName {
				_ = try await ZagUpdateVerifiedPipeline.accept(envelope: testEnvelope(sequence: 3, now: now), channel: "beta",
				                                               trustedKeys: keys, store: store, now: now)
			}
			check(replay?.contains("rollback") == true, "a lower sequence is still rejected afterwards (\(replay ?? "accepted"))")
			let production = ZagUpdateRollbackStore(service: "app.zagstore.ios.update-metadata-v2.production-beta")
			check(try await production.highestAccepted(channel: "beta") == nil,
			      "the production rollback record is never written by the harness")
		} catch {
			fail("rollback-state checks failed: \(error)")
		}

		allExtractedDigests += FR.importedDigests
		check(!allExtractedDigests.isEmpty && allExtractedDigests.allSatisfy { $0 == authenticSHA },
		      "every package the importer extracted matched the signed SHA-256 (\(allExtractedDigests.count) imports)")
		check(StubProtocol.unexpectedRequests.isEmpty,
		      "no request left the stub (unexpected: \(StubProtocol.unexpectedRequests))")
		for name in knownDefects.keys.sorted() where !observedDefects.contains(name) {
			fail("known defect \(name) was not exercised")
		}
		print("Summary: \(passes) mandatory checks passed, \(defects) known defects present, \(failures) failures")
		if failures == 0 {
			print("SUCCESS: self-update integrity checks passed")
			exit(0)
		}
		print("FAILED: \(failures) check(s) failed")
		exit(1)
	}
}

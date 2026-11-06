import Foundation

// Compiled with NimbleKit/Sources/NimbleJSON/NBFetchService.swift by
// scripts/test-zag-background-refresh.sh.
//
// Every UserDefaults write re-evaluates each SwiftUI view that holds
// @AppStorage, including the app's root tab view. Recording a fetch metric
// for every repository on every refresh must therefore not touch
// UserDefaults, while the diagnostics stay available.

@main struct ZagFetchDefaultsTests {
	static var failures = 0

	static func expect(_ condition: Bool, _ label: String) {
		print((condition ? "PASS  " : "FAIL  ") + label)
		if !condition { failures += 1 }
	}

	static func metric(_ url: String, _ status: String) -> NBRepositoryFetchMetric {
		NBRepositoryFetchMetric(url: url, status: status, byteCount: 10, networkSeconds: 0.1,
			decodeSeconds: 0.01, recordedAt: Date())
	}

	static func main() {
		let legacyKey = "ZagStore.RepositoryFetchMetrics"
		NBRepositoryFetchDiagnostics.clear()

		// Metrics written by older builds are still shown, then migrated once.
		let legacy = try! JSONEncoder().encode([metric("https://old.example/repo.json", "network/200")])
		UserDefaults.standard.set(legacy, forKey: legacyKey)
		expect(NBRepositoryFetchDiagnostics.metrics.map(\.url) == ["https://old.example/repo.json"],
			"metrics saved by older builds are still readable")
		NBRepositoryFetchDiagnostics.record(metric("https://a.example/repo.json", "network/200"))
		expect(UserDefaults.standard.object(forKey: legacyKey) == nil, "older metrics migrate out of UserDefaults once")

		// A full refresh's worth of metrics posts no UserDefaults change.
		var changes = 0
		let token = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in changes += 1 }
		for round in 0..<3 {
			for index in 0..<12 {
				NBRepositoryFetchDiagnostics.record(metric("https://r\(index).example/repo.json", "network/20\(round)"))
			}
		}
		NotificationCenter.default.removeObserver(token)
		expect(changes == 0, "36 recorded metrics cause no UserDefaults change (was one per repository), got \(changes)")

		let urls = Set(NBRepositoryFetchDiagnostics.metrics.map(\.url))
		expect(urls.count == 14, "every repository keeps exactly one latest metric (got \(urls.count))")
		expect(NBRepositoryFetchDiagnostics.metrics.first { $0.url == "https://r3.example/repo.json" }?.status == "network/202",
			"the newest metric replaces the previous one for its repository")

		NBRepositoryFetchDiagnostics.clear()
		expect(NBRepositoryFetchDiagnostics.metrics.isEmpty, "clearing diagnostics removes them")

		if failures > 0 { print("\(failures) fetch defaults test(s) failed"); exit(1) }
		print("All fetch defaults tests passed")
	}
}

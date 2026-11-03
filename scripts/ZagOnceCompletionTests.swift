import Foundation

// Compiled with Feather/Utilities/ZagOnceCompletion.swift by
// scripts/test-zag-background-refresh.sh.
@main struct ZagOnceCompletionTests {
	static func main() {
		var failures = 0
		func expect(_ condition: Bool, _ label: String) {
			print((condition ? "PASS  " : "FAIL  ") + label)
			if !condition { failures += 1 }
		}

		// Work finishes first, then expiry fires: only the success is reported.
		var results: [Bool] = []
		let finished = ZagOnceCompletion { results.append($0) }
		expect(finished.complete(success: true), "first completion runs")
		expect(!finished.complete(success: false), "expiry after completion is ignored")
		expect(results == [true], "work result reported once")

		// Expiry fires first, then cancelled work returns: only failure is reported.
		results = []
		let expired = ZagOnceCompletion { results.append($0) }
		expired.complete(success: false)
		expired.complete(success: true)
		expect(results == [false], "expiry reported once as failure")

		// Concurrent callers from many threads still complete exactly once.
		let lock = NSLock()
		var calls = 0
		let racing = ZagOnceCompletion { _ in lock.lock(); calls += 1; lock.unlock() }
		DispatchQueue.concurrentPerform(iterations: 1_000) { index in
			racing.complete(success: index.isMultiple(of: 2))
		}
		expect(calls == 1, "1000 concurrent completions run the handler once")

		if failures > 0 {
			print("\(failures) test(s) failed")
			exit(1)
		}
		print("All once-completion tests passed")
	}
}

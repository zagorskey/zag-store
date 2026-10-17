import Foundation

@main
struct ZagMetadataV2SequenceStoreTests {
    static func rejects(_ name: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            fatalError("FAIL: \(name) accepted")
        } catch {
            print("PASS: \(name) rejected")
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zag-v2-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sequence.json")
        let payload = Data("signed payload A".utf8)
        let changed = Data("signed payload B".utf8)

        let store = ZagMetadataV2SequenceStore(fileURL: url)
        try store.accept(channel: "beta", sequence: 7, signedPayload: payload)
        guard try store.read(channel: "beta")?.sequence == 7 else {
            fatalError("FAIL: Initial sequence not stored")
        }
        print("PASS: First accepted sequence persisted")

        let restarted = ZagMetadataV2SequenceStore(fileURL: url)
        try restarted.accept(channel: "beta", sequence: 7, signedPayload: payload)
        print("PASS: Identical sequence survives restart")
        try rejects("Older sequence after restart") {
            try restarted.accept(channel: "beta", sequence: 6, signedPayload: payload)
        }
        try rejects("Conflicting equal sequence") {
            try restarted.accept(channel: "beta", sequence: 7, signedPayload: changed)
        }
        try restarted.accept(channel: "stable", sequence: 2, signedPayload: changed)
        try restarted.accept(channel: "beta", sequence: 8, signedPayload: changed)
        guard try restarted.read(channel: "stable")?.sequence == 2,
              try restarted.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Independent channel state lost")
        }
        print("PASS: Independent channel sequences persisted")

        try rejects("Unknown channel cannot be recorded") {
            try restarted.accept(channel: "preview", sequence: 9, signedPayload: payload)
        }
        try rejects("Unknown channel cannot be read") {
            _ = try restarted.read(channel: "preview")
        }
        try rejects("Zero sequence cannot be recorded") {
            try restarted.accept(channel: "beta", sequence: 0, signedPayload: payload)
        }
        guard try restarted.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Rejected inputs changed persisted sequence")
        }
        print("PASS: Rejected inputs leave trusted sequence intact")

        // Exercise simultaneous writers against an independent on-disk snapshot.
        // Each writer has its own store instance, as separate update tasks would.
        let concurrentURL = directory.appendingPathComponent("concurrent-sequence.json")
        let workerCount = 8
        let gate = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let outcomes = DispatchQueue(label: "zag-v2-sequence-test-outcomes")
        var succeeded = 0
        var failures: [String] = []
        for sequence in 1...workerCount {
            finished.enter()
            DispatchQueue.global().async {
                gate.wait()
                do {
                    try ZagMetadataV2SequenceStore(fileURL: concurrentURL).accept(
                        channel: "beta",
                        sequence: sequence,
                        signedPayload: Data("sequence-\(sequence)".utf8))
                    outcomes.sync { succeeded += 1 }
                } catch {
                    outcomes.sync { failures.append("\(sequence): \(error)") }
                }
                finished.leave()
            }
        }
        for _ in 1...workerCount { gate.signal() }
        finished.wait()
        let concurrentResult = try ZagMetadataV2SequenceStore(fileURL: concurrentURL).read(channel: "beta")
        guard concurrentResult?.sequence == workerCount else {
            fatalError("FAIL: Concurrent sequence writers left stale state (final \(concurrentResult?.sequence.description ?? "nil"), successes \(succeeded), failures \(failures))")
        }
        print("PASS: Concurrent writes preserve highest accepted sequence")

        // A missing state file is a valid first-run condition, but must not
        // silently discard an existing high-water mark.
        let freshURL = directory.appendingPathComponent("fresh-state.json")
        let fresh = ZagMetadataV2SequenceStore(fileURL: freshURL)
        guard try fresh.read(channel: "beta") == nil else {
            fatalError("FAIL: First-run state was not empty")
        }
        try fresh.accept(channel: "beta", sequence: 12, signedPayload: payload)
        guard try ZagMetadataV2SequenceStore(fileURL: freshURL)
            .read(channel: "beta")?.sequence == 12 else {
            fatalError("FAIL: Fresh state high-water mark was not persisted")
        }
        print("PASS: New state starts empty and persists its first high-water mark")

        // A failed persistence attempt must not replace an already trusted
        // high-water mark. Simulate a directory where a file should be written.
        let blockedURL = directory.appendingPathComponent("blocked-sequence.json", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blockedURL, withIntermediateDirectories: true)
        let blocked = ZagMetadataV2SequenceStore(fileURL: blockedURL)
        try rejects("Unwritable state destination") {
            try blocked.accept(channel: "beta", sequence: 13, signedPayload: payload)
        }
        guard try restarted.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Failed persistence changed trusted high-water mark")
        }
        print("PASS: Failed persistence leaves existing trusted state unchanged")

        // Interrupted or truncated state must fail closed rather than initialize
        // a new empty snapshot and discard the previous rollback watermark.
        let truncatedURL = directory.appendingPathComponent("truncated-state.json")
        let truncatedStore = ZagMetadataV2SequenceStore(fileURL: truncatedURL)
        try truncatedStore.accept(channel: "beta", sequence: 15, signedPayload: payload)
        let originalBytes = try Data(contentsOf: truncatedURL)
        let truncatedBytes = Data(originalBytes.prefix(max(1, originalBytes.count / 2)))
        try truncatedBytes.write(to: truncatedURL, options: .atomic)
        try rejects("Truncated persisted state") {
            try truncatedStore.accept(channel: "beta", sequence: 16, signedPayload: changed)
        }
        guard try Data(contentsOf: truncatedURL) == truncatedBytes else {
            fatalError("FAIL: Rejected truncated state was overwritten")
        }
        print("PASS: Truncated state remains untouched after rejection")

        try Data("{invalid json".utf8).write(to: url, options: .atomic)
        try rejects("Corrupted state") {
            try restarted.accept(channel: "beta", sequence: 9, signedPayload: payload)
        }
        print("SUCCESS: Persistent channel sequence prototype tests passed")
    }
}

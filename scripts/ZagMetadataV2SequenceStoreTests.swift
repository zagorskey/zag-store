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

        // A replacement state inode must have owner-only permissions at the
        // time it becomes visible, not only after the rename completes.
        let secureURL = directory.appendingPathComponent("private-atomic-state.json")
        let secureStore = ZagMetadataV2SequenceStore(fileURL: secureURL)
        try secureStore.accept(channel: "beta", sequence: 1, signedPayload: payload)
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: secureURL.path)
        guard let initialMode = initialAttributes[.posixPermissions] as? NSNumber,
              initialMode.intValue & 0o777 == 0o600 else {
            fatalError("FAIL: New atomic state file is not owner-private")
        }
        print("PASS: Newly persisted state file has private permissions")
        try secureStore.accept(channel: "beta", sequence: 2, signedPayload: changed)
        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: secureURL.path)
        guard let replacementMode = replacementAttributes[.posixPermissions] as? NSNumber,
              replacementMode.intValue & 0o777 == 0o600,
              try secureStore.read(channel: "beta")?.sequence == 2 else {
            fatalError("FAIL: Atomic replacement lost private permissions or sequence")
        }
        print("PASS: Replaced state file remains private and preserves sequence")
        let temporaryEntries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard !temporaryEntries.contains(where: { $0.hasPrefix(".zag-v2-") && $0.hasSuffix(".tmp") }) else {
            fatalError("FAIL: Atomic write left temporary state files behind")
        }
        print("PASS: Successful atomic writes leave no temporary files")

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

        // A pre-planted symlink at the adjacent lock path must never be
        // followed or used to coordinate a trusted state transition.
        let symlinkURL = directory.appendingPathComponent("symlink-state.json")
        let symlinkTarget = directory.appendingPathComponent("symlink-lock-target.txt")
        let markerBytes = Data("DO NOT MODIFY LOCK TARGET".utf8)
        try markerBytes.write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path + ".lock", withDestinationPath: symlinkTarget.path)
        let symlinkStore = ZagMetadataV2SequenceStore(fileURL: symlinkURL)
        try rejects("Symbolic-link lock file on read") {
            _ = try symlinkStore.read(channel: "beta")
        }
        try rejects("Symbolic-link lock file on write") {
            try symlinkStore.accept(channel: "beta", sequence: 1, signedPayload: payload)
        }
        guard try Data(contentsOf: symlinkTarget) == markerBytes,
              !FileManager.default.fileExists(atPath: symlinkURL.path) else {
            fatalError("FAIL: Lock-file symlink rejection changed the target or persisted state")
        }
        print("PASS: Lock-file symlink rejection leaves target and state untouched")

        // Symlinks at the state path must fail closed, including dangling
        // symlinks (which fileExists incorrectly treats as absent).
        let linkedStateURL = directory.appendingPathComponent("linked-state.json")
        let linkedTargetURL = directory.appendingPathComponent("linked-target.txt")
        let linkedMarker = Data("DO NOT MODIFY STATE LINK TARGET".utf8)
        try linkedMarker.write(to: linkedTargetURL)
        try FileManager.default.createSymbolicLink(
            atPath: linkedStateURL.path, withDestinationPath: linkedTargetURL.path)
        let linkedStore = ZagMetadataV2SequenceStore(fileURL: linkedStateURL)
        try rejects("Symbolic-link state file on read") {
            _ = try linkedStore.read(channel: "beta")
        }
        try rejects("Symbolic-link state file on write") {
            try linkedStore.accept(channel: "beta", sequence: 1, signedPayload: payload)
        }
        guard try Data(contentsOf: linkedTargetURL) == linkedMarker,
              (try FileManager.default.destinationOfSymbolicLink(
                  atPath: linkedStateURL.path)) == linkedTargetURL.path else {
            fatalError("FAIL: State symlink rejection changed the target")
        }
        print("PASS: State-file symlink rejection preserves target")

        let danglingStateURL = directory.appendingPathComponent("dangling-state.json")
        let nonexistentTargetURL = directory.appendingPathComponent("not-created-state.json")
        try FileManager.default.createSymbolicLink(
            atPath: danglingStateURL.path,
            withDestinationPath: nonexistentTargetURL.path)
        let danglingStore = ZagMetadataV2SequenceStore(fileURL: danglingStateURL)
        try rejects("Dangling symbolic-link state on read") {
            _ = try danglingStore.read(channel: "beta")
        }
        try rejects("Dangling symbolic-link state on write") {
            try danglingStore.accept(channel: "beta", sequence: 1, signedPayload: payload)
        }
        guard !FileManager.default.fileExists(atPath: nonexistentTargetURL.path),
              (try FileManager.default.destinationOfSymbolicLink(
                  atPath: danglingStateURL.path)) == nonexistentTargetURL.path else {
            fatalError("FAIL: Dangling state symlink modified destination")
        }
        print("PASS: Dangling state symlink leaves destination untouched")

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

        // Valid JSON with an unsupported format must not be interpreted as
        // a fresh state file or overwritten by a subsequent update.
        let futureFormatURL = directory.appendingPathComponent("future-format-state.json")
        let futureFormatBytes = Data(#"{"format":2,"channels":{}}"#.utf8)
        try futureFormatBytes.write(to: futureFormatURL, options: .atomic)
        let futureFormatStore = ZagMetadataV2SequenceStore(fileURL: futureFormatURL)
        try rejects("Unsupported persisted state format") {
            try futureFormatStore.accept(channel: "beta", sequence: 16, signedPayload: payload)
        }
        guard try Data(contentsOf: futureFormatURL) == futureFormatBytes else {
            fatalError("FAIL: Unsupported state format was overwritten")
        }
        print("PASS: Unsupported state format remains untouched after rejection")

        try Data("{invalid json".utf8).write(to: url, options: .atomic)
        try rejects("Corrupted state") {
            try restarted.accept(channel: "beta", sequence: 9, signedPayload: payload)
        }
        print("SUCCESS: Persistent channel sequence prototype tests passed")
    }
}

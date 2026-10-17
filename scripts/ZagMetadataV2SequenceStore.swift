import Foundation
import CryptoKit

/// Offline prototype only. Not connected to the running Zag Store updater.
/// Production will use a protected Application Support location and a defined
/// backup/restore policy. Deleting all local app state defeats local rollback memory.
struct ZagMetadataV2SequenceStore {
    enum StoreError: Error {
        case invalidChannel, corruptState, conflictingSequence, rollback
    }

    struct Entry: Codable, Equatable {
        let sequence: Int
        let digest: String
    }

    private struct Snapshot: Codable {
        let format: Int
        var channels: [String: Entry]
    }

    let fileURL: URL

    // Serialize read-modify-write operations across all instances in this process.
    // Cross-process writers still require a separate OS-level locking strategy.
    private static let processLock = NSRecursiveLock()


    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.format == 1 else { throw StoreError.corruptState }
        for (channel, entry) in snapshot.channels {
            guard ["stable", "beta", "nightly"].contains(channel),
                  entry.sequence > 0,
                  entry.digest.count == 64,
                  entry.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw StoreError.corruptState }
        }
    }

    private func load() throws -> Snapshot {
        // Distinguish absent state from unreadable/corrupt state.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot(format: 1, channels: [:])
        }
        do {
            let bytes = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: bytes)
            try validate(snapshot)
            return snapshot
        } catch {
            throw StoreError.corruptState
        }
    }

    func read(channel: String) throws -> Entry? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard ["stable", "beta", "nightly"].contains(channel) else {
            throw StoreError.invalidChannel
        }
        return try load().channels[channel]
    }

    /// In-process access is serialized across instances. Cross-process callers
    /// still require coordination; atomic replacement alone is insufficient.
    func accept(channel: String, sequence: Int, signedPayload: Data) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard ["stable", "beta", "nightly"].contains(channel), sequence > 0 else {
            throw StoreError.invalidChannel
        }
        let digest = SHA256.hash(data: signedPayload)
            .map { String(format: "%02x", $0) }.joined()
        var snapshot = try load()
        if let prior = snapshot.channels[channel] {
            if sequence < prior.sequence { throw StoreError.rollback }
            if sequence == prior.sequence {
                guard digest == prior.digest else { throw StoreError.conflictingSequence }
                return
            }
        }
        snapshot.channels[channel] = Entry(sequence: sequence, digest: digest)
        let bytes = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: fileURL, options: .atomic)
    }
}

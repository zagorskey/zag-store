import Foundation
import CryptoKit
import Darwin

/// Offline prototype only. Not connected to the running Zag Store updater.
/// Production will use a protected Application Support location and a defined
/// backup/restore policy. Deleting all local app state defeats local rollback memory.
struct ZagMetadataV2SequenceStore {
    enum StoreError: Error {
        case invalidChannel, corruptState, conflictingSequence, rollback, lockUnavailable
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
    // Cross-process access uses an adjacent advisory flock lock file.
    private static let processLock = NSRecursiveLock()


    /// Use a stable adjacent lock file, not the atomically replaced state inode.
    /// All cooperating processes must use this protocol for the same file URL.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let lockPath = fileURL.path + ".lock"
        // Refuse a pre-planted symlink and enforce a private regular lock file.
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StoreError.lockUnavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & mode_t(0o077)) == 0 else {
            _ = close(descriptor)
            throw StoreError.lockUnavailable
        }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.lockUnavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

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
        // Open the state file itself with no symlink following. Only ENOENT
        // represents a fresh installation; a dangling link must fail closed.
        let fd = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT {
                return Snapshot(format: 1, channels: [:])
            }
            throw StoreError.corruptState
        }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & mode_t(0o077)) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= 1024 * 1024 else {
            throw StoreError.corruptState
        }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let bytes = handle.readDataToEndOfFile()
            guard bytes.count <= 1024 * 1024 else { throw StoreError.corruptState }
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
        return try withFileLock { try load().channels[channel] }
    }

    /// Both threads and cooperating processes serialize the complete read-modify-write.
    /// Do not delete the adjacent .lock file while another process may use it.
    func accept(channel: String, sequence: Int, signedPayload: Data) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard ["stable", "beta", "nightly"].contains(channel), sequence > 0 else {
            throw StoreError.invalidChannel
        }
        try withFileLock {
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
            // Foundation atomic writes use a replacement inode whose mode is
            // not guaranteed to be private. Set owner-only permissions before
            // any subsequent read applies the strict state-file checks.
            try bytes.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path)
        }
    }
}

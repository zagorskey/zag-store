import Foundation
import CryptoKit
import Darwin

/// Offline-only digest boundary. The expected hash MUST come from metadata
/// whose signature, channel and policy were independently verified.
/// This does not authorize installation or advance anti-rollback state.
enum ZagMetadataV2ArtifactHash {
    enum Failure: Error {
        case invalidExpectedHash, unsafeFile, oversizedFile, unreadableFile, digestMismatch
    }

    /// Refuse unbounded reads; production policy must review this limit.
    static let maximumBytes: Int64 = 1024 * 1024 * 1024

    static func verify(fileURL: URL, expectedSHA256: String) throws {
        guard expectedSHA256.utf8.count == 64,
              expectedSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { throw Failure.invalidExpectedHash }

        let fd = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unreadableFile }
        defer { _ = close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_size > 0 else { throw Failure.unsafeFile }
        guard before.st_size <= maximumBytes else { throw Failure.oversizedFile }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unreadableFile }
            if count == 0 { break }
            total += Int64(count)
            guard total <= maximumBytes else { throw Failure.oversizedFile }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              total == before.st_size, total == after.st_size,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw Failure.unsafeFile
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else { throw Failure.digestMismatch }
    }
}

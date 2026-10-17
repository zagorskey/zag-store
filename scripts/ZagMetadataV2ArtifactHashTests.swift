import Foundation
import CryptoKit
import Darwin

@main
struct ZagMetadataV2ArtifactHashTests {
    enum TestFailure: Error { case expectedRejection(String) }

    static func reject(
        _ label: String,
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
            throw TestFailure.expectedRejection(label)
        } catch TestFailure.expectedRejection {
            throw TestFailure.expectedRejection(label)
        } catch {
            print("PASS: \(label) rejected")
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zag-v2-artifact-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ipa = directory.appendingPathComponent("sample.ipa")
        let contents = Data(repeating: 0x5a, count: 192 * 1024 + 17)
        try contents.write(to: ipa)
        let digest = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }.joined()

        try ZagMetadataV2ArtifactHash.verify(
            fileURL: ipa, expectedSHA256: digest)
        print("PASS: Correct digest accepted for multi-chunk artifact")

        try reject("Modified artifact bytes") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: ipa, expectedSHA256: String(repeating: "0", count: 64))
        }
        try reject("Malformed expected hash") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: ipa, expectedSHA256: "not-a-sha256")
        }
        try reject("Uppercase expected hash") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: ipa, expectedSHA256: digest.uppercased())
        }

        let missing = directory.appendingPathComponent("missing.ipa")
        try reject("Missing artifact") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: missing, expectedSHA256: digest)
        }
        try reject("Directory instead of artifact") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: directory, expectedSHA256: digest)
        }

        let link = directory.appendingPathComponent("linked.ipa")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: ipa)
        try reject("Symbolic-link artifact") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: link, expectedSHA256: digest)
        }

        let empty = directory.appendingPathComponent("empty.ipa")
        try Data().write(to: empty)
        try reject("Empty artifact") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: empty,
                expectedSHA256: SHA256.hash(data: Data())
                    .map { String(format: "%02x", $0) }.joined())
        }

        let tampered = directory.appendingPathComponent("tampered.ipa")
        var modified = contents
        modified[modified.count - 1] ^= 1
        try modified.write(to: tampered)
        try reject("Same-length changed artifact") {
            try ZagMetadataV2ArtifactHash.verify(
                fileURL: tampered, expectedSHA256: digest)
        }

        print("SUCCESS: Offline artifact SHA-256 verification tests passed")
    }
}

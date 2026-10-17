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
              restarted.read(channel: "beta")?.sequence == 8 else {
            fatalError("FAIL: Independent channel state lost")
        }
        print("PASS: Independent channel sequences persisted")

        try Data("{invalid json".utf8).write(to: url, options: .atomic)
        try rejects("Corrupted state") {
            try restarted.accept(channel: "beta", sequence: 9, signedPayload: payload)
        }
        print("SUCCESS: Persistent channel sequence prototype tests passed")
    }
}

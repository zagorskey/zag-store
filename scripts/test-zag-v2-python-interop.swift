import Foundation
import Security

@main
struct PythonJCSInteropTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: test-zag-v2-python-interop <fixture-directory>\n", stderr)
            exit(2)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let envelope = try Data(contentsOf: folder.appendingPathComponent("envelope.json"))
        let publicKey = try Data(contentsOf: folder.appendingPathComponent("public-key.raw"))
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        let service = "app.zagstore.ios.python-interop.\(UUID().uuidString)"
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        let store = ZagUpdateRollbackStore(service: service)
        let payload = try await ZagUpdateVerifiedPipeline.accept(
            envelope: envelope, channel: "beta",
            trustedKeys: ["disposable-python-jcs": publicKey],
            store: store, now: now
        )
        guard payload.sequence == 11,
              payload.releaseNotes == "Обновяване — Café ☕ 日本語 🔐",
              try await store.highestAccepted(channel: "beta") == 11 else {
            fputs("FAIL: signed Python Unicode fixture mismatch\n", stderr)
            exit(1)
        }
        print("PASS: Python JCS Ed25519 signature verified in Swift")
        print("PASS: Unicode release notes preserved")
        print("PASS: Keychain rollback sequence persisted")
        print("SUCCESS: Python-to-Swift v2 integration passed")
    }
}

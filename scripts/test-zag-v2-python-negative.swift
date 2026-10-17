import Foundation
import Security

// Negative cross-language cases against the actual staged pipeline.
// Uses only disposable public key and isolated Keychain state.
@main
struct PythonJCSNegativeInterop {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let original = try Data(contentsOf: folder.appendingPathComponent("envelope.json"))
        let key = try Data(contentsOf: folder.appendingPathComponent("public-key.raw"))
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        let service = "app.zagstore.ios.python-negative.\(UUID().uuidString)"
        let store = ZagUpdateRollbackStore(service: service)
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        let keys = ["disposable-python-jcs": key]
        func verify(_ data: Data, channel: String = "beta") async throws {
            _ = try await ZagUpdateVerifiedPipeline.accept(
                envelope: data, channel: channel, trustedKeys: keys,
                store: store, now: now
            )
        }
        try await verify(original)
        guard try await store.highestAccepted(channel: "beta") == 11 else {
            fatalError("Valid baseline did not persist")
        }
        print("PASS: Python-signed baseline accepted")

        let text = String(data: original, encoding: .utf8)!
        let object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        func canonical(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        var tamperedPayload = object
        let payload = Data(base64Encoded: object["payload"] as! String)!
        var payloadText = String(data: payload, encoding: .utf8)!
        payloadText = payloadText.replacingOccurrences(of: "Обновяване", with: "Подмяна")
        tamperedPayload["payload"] = Data(payloadText.utf8).base64EncodedString()

        var wrongKey = object
        wrongKey["keyId"] = "unknown-key"
        var badSignature = object
        badSignature["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        var extraField = object
        extraField["unexpected"] = true

        let attacks: [(String, Data, String)] = [
            ("tampered Python payload", try canonical(tamperedPayload), "beta"),
            ("untrusted key ID", try canonical(wrongKey), "beta"),
            ("forged signature", try canonical(badSignature), "beta"),
            ("unexpected envelope field", try canonical(extraField), "beta"),
            ("duplicate envelope key", Data(text.replacingOccurrences(
                of: "\"schema\":2,", with: "\"schema\":2,\"schema\":2,"
            ).utf8), "beta"),
            ("wrong channel", original, "stable")
        ]
        var failures = 0
        for (name, data, channel) in attacks {
            do {
                try await verify(data, channel: channel)
                print("FAIL: \(name) accepted")
                failures += 1
            } catch {
                print("PASS: \(name) rejected")
            }
        }
        let beta = try await store.highestAccepted(channel: "beta")
        let stable = try await store.highestAccepted(channel: "stable")
        if beta == 11 && stable == nil {
            print("PASS: rejected manifests did not change Keychain history")
        } else {
            print("FAIL: rejected manifests changed Keychain history")
            failures += 1
        }
        guard failures == 0 else { exit(1) }
        print("SUCCESS: Python-to-Swift negative interoperability tests passed")
    }
}

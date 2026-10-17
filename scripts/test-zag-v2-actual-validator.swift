import Foundation
import CryptoKit

// Compile with Feather/Utilities/ZagUpdateMetadataV2.swift to exercise the
// exact staged validator shipped in the app, not a reimplementation.
@main
struct MetadataGateTests {
    static func main() throws {
        let fixtures: [(String, String, Bool)] = [
            ("sorted compact object", #"{"a":1,"b":"hello"}"#, true),
            ("duplicate key", #"{"a":1,"a":2}"#, false),
            ("escaped duplicate key", #"{"a":1,"\u0061":2}"#, false),
            ("extra whitespace", #"{ "a":1,"b":"hello"}"#, false),
            ("unsorted keys", #"{"b":"hello","a":1}"#, false),
            ("alternate number spelling", #"{"a":1.0,"b":"hello"}"#, false),
            ("non-ASCII string", #"{"a":"café"}"#, false),
            ("escaped slash", #"{"a":"https:\/\/example.com"}"#, false)
        ]
        var failed = 0
        for (name, json, expected) in fixtures {
            let bytes = Data(json.utf8)
            let accepted: Bool
            if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               JSONSerialization.isValidJSONObject(object),
               let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) {
                accepted = bytes.allSatisfy({ $0 < 128 }) && canonical == bytes
            } else {
                accepted = false
            }
            if accepted != expected { failed += 1; print("FAIL: \(name)") }
            else { print("PASS: \(name)") }
        }
        // Invoke the actual validator on a complete canonical v2 payload.
        let values: [String: Any] = [
            "schema": 2, "appId": "app.zagstore.ios", "channel": "beta",
            "sequence": 1, "version": "1.0.0", "build": "3",
            "minimumIOSVersion": "16.0",
            "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa",
            "sha256": String(repeating: "a", count: 64),
            "releaseNotes": "Test", "publishedAt": "2026-10-17T00:00:00Z",
            "expiresAt": "2026-10-18T00:00:00Z"
        ]
        let valid = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        do {
            _ = try ZagUpdateMetadataV2.validatePayload(valid, channel: "beta", now: now)
            print("PASS: actual validator accepted canonical payload")
        } catch {
            failed += 1
            print("FAIL: actual validator rejected canonical payload: \(error)")
        }
        for (name, data) in [
            ("actual validator duplicate key", Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: #"{"appId":"#, with: #"{"appId":"wrong","appId":"#).utf8)),
            ("actual validator whitespace", Data((" " + String(decoding: valid, as: UTF8.self)).utf8))
        ] {
            do {
                _ = try ZagUpdateMetadataV2.validatePayload(data, channel: "beta", now: now)
                failed += 1
                print("FAIL: \(name) accepted")
            } catch { print("PASS: \(name) rejected") }
        }
        guard failed == 0 else { exit(1) }
        print("SUCCESS: actual ZagUpdateMetadataV2 validator tests passed")
    }
}

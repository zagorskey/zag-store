import Foundation

// Characterization test for the staged ASCII-only v2 JSON canonicality gate.
// This mirrors the gate in ZagSelfUpdateCoordinator; it does not execute app code.
func accepts(_ text: String) -> Bool {
    let bytes = Data(text.utf8)
    guard bytes.allSatisfy({ $0 < 128 }),
          let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          JSONSerialization.isValidJSONObject(object),
          let canonical = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
          ) else { return false }
    return canonical == bytes
}

let fixtures: [(String, String, Bool)] = [
    ("sorted compact object", #"{"a":1,"b":"hello"}"#, true),
    ("duplicate key", #"{"a":1,"a":2}"#, false),
    ("escaped duplicate key", #"{"a":1,"\u0061":2}"#, false),
    ("extra whitespace", #"{ "a":1,"b":"hello"}"#, false),
    ("unsorted keys", #"{"b":"hello","a":1}"#, false),
    ("alternate number spelling", #"{"a":1.0,"b":"hello"}"#, false),
    ("non-ASCII string", #"{"a":"café"}"#, false),
    ("escaped slash", #"{"a":"https:\/\/example.com"}"#, false),
]
var failed = 0
for (name, json, expected) in fixtures {
    let actual = accepts(json)
    print("\(actual == expected ? "PASS" : "FAIL"): \(name) (accepted=\(actual))")
    if actual != expected { failed += 1 }
}
guard failed == 0 else {
    fputs("FAIL: \(failed) canonical JSON gate fixtures differed from expectations\n", stderr)
    exit(1)
}
print("SUCCESS: ASCII canonical JSON gate characterization passed")

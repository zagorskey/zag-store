import Foundation

// Characterization only. This is NOT an RFC 8785 implementation.
// Compare the hex bytes below against Python jcs.canonicalize for each case.
let cases = [
    "ASCII release notes",
    "Обновяване на Заг Стор",
    "Café ☕ — 日本語",
    "Quotes \" slash / backslash \\ tab \t newline \n",
    "Emoji 🔐🚀 and combining e\u{301}"
]
for (index, notes) in cases.enumerated() {
    let value: [String: Any] = ["releaseNotes": notes, "schema": 2]
    let bytes = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    print("CASE \(index): \(bytes.map { String(format: "%02x", $0) }.joined())")
}

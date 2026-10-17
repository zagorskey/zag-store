import Foundation

// Characterization only, not a full RFC 8785 implementation.
// The Python comparison uses the same indexed fixtures.
let cases: [[String: Any]] = [
    ["releaseNotes": "ASCII release notes", "schema": 2],
    ["releaseNotes": "Обновяване на Заг Стор", "schema": 2],
    ["releaseNotes": "Café ☕ — 日本語", "schema": 2],
    ["releaseNotes": "Quotes \" slash / backslash \\ tab \t newline \n", "schema": 2],
    ["releaseNotes": "Emoji 🔐🚀 and combining e\u{301}", "schema": 2],
    ["releaseNotes": "Control \u{0008}\u{000C}\u{0000}\u{001F}", "schema": 2],
    ["releaseNotes": "Line separators \u{2028}\u{2029}", "schema": 2],
    ["releaseNotes": "Supplementary 𝄞 and ZWJ 👩‍💻", "schema": 2],
    ["releaseNotes": "Latin Å vs A\u{030A}", "schema": 2],
    ["releaseNotes": "HTML <script>&", "schema": 2],
    ["releaseNotes": "Value", "schema": 2, "amount": 1.0],
    ["releaseNotes": "Value", "schema": 2, "amount": 1e-7],
    ["releaseNotes": "Value", "schema": 2, "amount": 1e21],
    ["releaseNotes": "Value", "schema": 2, "amount": -0.0],
    ["releaseNotes": "Value", "schema": 2, "amount": 333333333.3333333],
    ["releaseNotes": "Value", "schema": 2, "amount": 0.000001],
]
for (index, value) in cases.enumerated() {
    let bytes = try JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
    )
    print("CASE \(index): \(bytes.map { String(format: "%02x", $0) }.joined())")
}

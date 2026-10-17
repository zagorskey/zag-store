import Foundation

@main
struct TrustStoreTests {
    static func main() {
        guard ZagUpdateTrustStore.productionKeys.isEmpty else {
            fputs("FAIL: production trust registry must remain unprovisioned\n", stderr)
            exit(1)
        }
        print("PASS: production trust registry starts empty")
        for id in ["test-key", "disposable-python-jcs", "", String(repeating: "x", count: 65)] {
            guard ZagUpdateTrustStore.publicKey(for: id) == nil else {
                fputs("FAIL: unprovisioned key accepted: \(id)\n", stderr)
                exit(1)
            }
        }
        print("PASS: disposable, missing and invalid key IDs not trusted")
        print("SUCCESS: staged production trust store fails closed")
    }
}

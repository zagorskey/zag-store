import Foundation
import CryptoKit

@main
struct TrustStoreTests {
    static func main() {
        let expectedHex = "97d3cdfae45c59280ad546bcd48f43bdb20b503cadc1d7c018b4a45893b3109b"
        let expectedFingerprint = "844fe8a9856d5e7ebc09c94f5d73acb8e61fb0d26a40d6533e3d9ee65616efa0"
        let keys = ZagUpdateTrustStore.productionKeys
        guard keys.count == 1,
              let key = ZagUpdateTrustStore.publicKey(for: "zag-v2-2026-b"),
              key.count == 32,
              key.map({ String(format: "%02x", $0) }).joined() == expectedHex else {
            fatalError("Production trust anchor mismatch")
        }
        print("PASS: exact reviewed production public key provisioned")
        let fingerprint = Data(SHA256.hash(data: key)).map { String(format: "%02x", $0) }.joined()
        guard fingerprint == expectedFingerprint else { fatalError("Production fingerprint mismatch") }
        print("PASS: production key SHA-256 fingerprint verified")
        for id in ["zag-v2-2026-a", "test-key", "disposable-python-jcs", "", String(repeating: "x", count: 65)] {
            guard ZagUpdateTrustStore.publicKey(for: id) == nil else {
                fatalError("Unexpected key trusted")
            }
        }
        print("PASS: disposable, retired, missing and invalid key IDs rejected")
        print("SUCCESS: production public trust anchor checks passed")
    }
}

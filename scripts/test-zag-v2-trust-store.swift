import Foundation
import CryptoKit

@main
struct TrustStoreTests {
    static func main() {
        let expectedHex = "97c762c6062134d6c38129751029463e0ad51f56a2a473e5cc0fa937d2d12d6c"
        let expectedFingerprint = "1310a5ac9ccfbc82ac3f3dcb3e6eb1c90fd68fcb1efb3cbf59a647de04568e48"
        let keys = ZagUpdateTrustStore.productionKeys
        guard keys.count == 1,
              let key = ZagUpdateTrustStore.publicKey(for: "zag-v2-2026-a"),
              key.count == 32,
              key.map({ String(format: "%02x", $0) }).joined() == expectedHex else {
            fatalError("Production trust anchor mismatch")
        }
        print("PASS: exact reviewed production public key provisioned")
        let fingerprint = Data(SHA256.hash(data: key)).map { String(format: "%02x", $0) }.joined()
        guard fingerprint == expectedFingerprint else { fatalError("Production fingerprint mismatch") }
        print("PASS: production key SHA-256 fingerprint verified")
        for id in ["test-key", "disposable-python-jcs", "", String(repeating: "x", count: 65)] {
            guard ZagUpdateTrustStore.publicKey(for: id) == nil else {
                fatalError("Unexpected key trusted")
            }
        }
        print("PASS: disposable, missing and invalid key IDs rejected")
        print("SUCCESS: production public trust anchor checks passed")
    }
}

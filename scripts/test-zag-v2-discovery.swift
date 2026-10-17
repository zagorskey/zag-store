import Foundation

@main
struct V2DiscoveryPreflightTests {
    static func main() async {
        let validURL = URL(string: "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/beta.v2.json")!
        let badURL = URL(string: "http://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/beta.v2.json")!
        var failures = 0

        func rejects(_ name: String, expected: String, _ run: () async throws -> Void) async {
            do {
                try await run()
                print("FAIL: \(name) accepted")
                failures += 1
            } catch {
                let got = String(describing: error)
                guard got.contains(expected) else {
                    print("FAIL: \(name) produced \(got), expected \(expected)")
                    failures += 1
                    return
                }
                print("PASS: \(name) rejected (\(got))")
            }
        }

        await rejects("empty production trust", expected: "unprovisionedTrust") {
            _ = try await ZagUpdateV2Discovery.fetchVerified(from: validURL, channel: "beta")
        }
        await rejects("invalid channel", expected: "invalidChannel") {
            _ = try await ZagUpdateV2Discovery.fetchVerified(from: validURL, channel: "preview")
        }
        await rejects("insecure scheme", expected: "insecureURL") {
            _ = try await ZagUpdateV2Discovery.fetchVerified(
                from: badURL, channel: "beta", trustedKeys: ["test": Data(repeating: 1, count: 32)])
        }
        guard failures == 0 else { exit(1) }
        print("SUCCESS: staged v2 discovery preflight fails closed")
    }
}

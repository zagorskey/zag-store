import Foundation
import Security

// Real HTTPS integration check. Never touches live update discovery or Keychain.
@main
struct V2PublishedBetaDiscoveryTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let url = URL(string: CommandLine.arguments[1]) else {
            fputs("Usage: test-zag-v2-published-beta-discovery <raw-https-url> <local-envelope.json>\n", stderr)
            exit(2)
        }
        let local = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let service = "app.zagstore.ios.published-beta-test.\(UUID().uuidString)"
        let store = ZagUpdateRollbackStore(service: service)
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (remote, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200, remote == local else {
            fatalError("Published bytes differ from locally signed envelope")
        }
        print("PASS: HTTPS endpoint serves exact signed envelope bytes")

        // Expected values come from the local signed envelope, so the check
        // follows each published release instead of hard-coding one.
        let envelope = try JSONSerialization.jsonObject(with: local) as! [String: Any]
        let expected = try JSONSerialization.jsonObject(
            with: Data(base64Encoded: envelope["payload"] as! String)!
        ) as! [String: Any]
        let expectedSequence = expected["sequence"] as! Int

        let payload = try await ZagUpdateV2Discovery.fetchVerified(
            from: url, channel: "beta",
            trustedKeys: ZagUpdateTrustStore.productionKeys,
            store: store, session: session
        )
        guard payload.version == expected["version"] as? String,
              payload.build == expected["build"] as? String,
              payload.sequence == expectedSequence,
              payload.sha256 == expected["sha256"] as? String,
              try await store.highestAccepted(channel: "beta") == expectedSequence else {
            fatalError("Verified discovery returned unexpected metadata")
        }
        print("PASS: real HTTPS discovery authenticated production-signed Beta")
        print("PASS: isolated Keychain accepted sequence \(expectedSequence)")

        do {
            _ = try await ZagUpdateV2Discovery.fetchVerified(
                from: url, channel: "stable",
                trustedKeys: ZagUpdateTrustStore.productionKeys,
                store: store, session: session
            )
            fatalError("Wrong channel was accepted")
        } catch {
            print("PASS: wrong-channel discovery rejected")
        }
        guard try await store.highestAccepted(channel: "stable") == nil,
              try await store.highestAccepted(channel: "beta") == expectedSequence else {
            fatalError("Rejected discovery modified rollback history")
        }
        print("PASS: rejected request did not change isolated rollback history")
        print("SUCCESS: published Beta v2 HTTPS discovery integration passed")
    }
}

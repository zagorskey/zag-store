import Foundation

/// Read-only authenticated update metadata discovery for future v2 rollout.
/// Intentionally NOT connected to ZagSelfUpdateCoordinator or live channels.
/// A missing production key must fail closed, before any network request.
enum ZagUpdateV2Discovery {
    enum DiscoveryError: Error, LocalizedError {
        case unprovisionedTrust, invalidChannel, insecureURL
        case invalidResponse, httpStatus(Int), oversizedResponse

        var errorDescription: String? {
            switch self {
            case .unprovisionedTrust: return "This version of Zag Store has no update signing key."
            case .invalidChannel: return "This update channel isn't supported."
            case .insecureURL: return "The update address isn't secure."
            case .invalidResponse: return "The update server sent an unexpected response."
            case .httpStatus(404): return "No update information is published for this channel yet."
            case .httpStatus(let code): return "The update server responded with HTTP \(code)."
            case .oversizedResponse: return "The update information is too large."
            }
        }
    }

    static let maximumEnvelopeBytes = 256 * 1024

    /// Delegate-owned request rejects redirects and limits buffered bytes
    /// as they arrive, including responses without Content-Length.
    private final class LimitedTransfer: NSObject, URLSessionDataDelegate {
        let maximumBytes: Int
        private var received = Data()
        private var receivedResponse: URLResponse?
        private var terminalError: Error?
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func start(request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                self.continuation = continuation
                session.dataTask(with: request).resume()
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            receivedResponse = response
            if response.expectedContentLength > Int64(maximumBytes) {
                terminalError = DiscoveryError.oversizedResponse
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            if data.count > maximumBytes - received.count {
                terminalError = DiscoveryError.oversizedResponse
                dataTask.cancel()
            } else {
                received.append(data)
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard let continuation else { return }
            self.continuation = nil
            if let terminalError { continuation.resume(throwing: terminalError) }
            else if let error { continuation.resume(throwing: error) }
            else if let receivedResponse {
                continuation.resume(returning: (received, receivedResponse))
            } else { continuation.resume(throwing: DiscoveryError.invalidResponse) }
        }
    }

    /// Fetch only the caller-provided HTTPS endpoint, verify its signed metadata,
    /// and persist accepted rollback state through the staged pipeline.
    /// Tests can inject a disposable trust map; production uses an empty map
    /// until independently reviewed public keys are provisioned.
    static func fetchVerified(
        from url: URL,
        channel: String,
        trustedKeys: [String: Data] = ZagUpdateTrustStore.productionKeys,
        store: ZagUpdateRollbackStore = .shared,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> ZagUpdateMetadataV2.Payload {
        guard ["stable", "beta", "nightly"].contains(channel) else {
            throw DiscoveryError.invalidChannel
        }
        guard !trustedKeys.isEmpty else {
            throw DiscoveryError.unprovisionedTrust
        }
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.host?.lowercased() == "raw.githubusercontent.com",
              url.path.hasPrefix("/zagorskey/zag-store-releases/") else {
            throw DiscoveryError.insecureURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        // An isolated URLSession ensures this delegate actually receives
        // response and data callbacks; never rely on a task-only delegate.
        let configuration = session.configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let delegate = LimitedTransfer(maximumBytes: maximumEnvelopeBytes)
        let transferSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { transferSession.finishTasksAndInvalidate() }
        let (data, response) = try await delegate.start(request: request, session: transferSession)
        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw DiscoveryError.httpStatus(http.statusCode)
        }
        guard http.expectedContentLength <= Int64(maximumEnvelopeBytes),
              data.count <= maximumEnvelopeBytes else {
            throw DiscoveryError.oversizedResponse
        }

        return try await ZagUpdateVerifiedPipeline.accept(
            envelope: data, channel: channel, trustedKeys: trustedKeys,
            store: store, now: now
        )
    }
}

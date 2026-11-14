import Foundation
import CryptoKit

/// SHA-256 verification of a package file against a signed digest.
///
/// The importer calls this on its own private working copy, the exact file
/// it then extracts, so the verified bytes are the imported bytes.
enum ZagPackageIntegrity {
	enum Failure: Error, LocalizedError {
		case checksumMismatch
		case unexpectedResponse

		var errorDescription: String? {
			switch self {
			case .checksumMismatch: "The package does not match its signed SHA-256."
			case .unexpectedResponse: "The package download did not return HTTP 200."
			}
		}
	}

	/// Streams the file in 1 MiB chunks so large IPAs are not held in memory.
	static func sha256(of url: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher = SHA256()
		while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	static func verify(_ url: URL, expectedSHA256: String) throws {
		guard try sha256(of: url).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
			throw Failure.checksumMismatch
		}
	}

	/// Streams `url` into `file`, which the caller creates and owns, hashing
	/// each chunk as it is written, and throws unless the body matches
	/// `expectedSHA256`. Memory use is bounded by URLSession's chunk size.
	/// Nothing else is written: no download task, so no temporary file that
	/// outlives a dropped connection. Cancelling the calling task cancels the
	/// request. On any error `file` holds unverified bytes and must be removed.
	static func download(
		_ url: URL,
		expectedSHA256: String,
		session: URLSession,
		to file: URL
	) async throws {
		let handle = try FileHandle(forWritingTo: file)
		defer { try? handle.close() }
		let receiver = StreamingReceiver(handle: handle)
		let task = session.dataTask(with: url)
		task.delegate = receiver
		let digest = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				receiver.continuation = continuation
				task.resume()
			}
		} onCancel: {
			task.cancel()
		}
		try Task.checkCancellation()
		try handle.synchronize()
		guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
			throw Failure.checksumMismatch
		}
	}

	/// URLSession calls these serially on its delegate queue.
	private final class StreamingReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
		private let handle: FileHandle
		private var hasher = SHA256()
		private var failure: Error?
		var continuation: CheckedContinuation<String, Error>?

		init(handle: FileHandle) {
			self.handle = handle
		}

		func urlSession(
			_ session: URLSession,
			dataTask: URLSessionDataTask,
			didReceive response: URLResponse,
			completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
		) {
			guard (response as? HTTPURLResponse)?.statusCode == 200 else {
				failure = Failure.unexpectedResponse
				completionHandler(.cancel)
				return
			}
			completionHandler(.allow)
		}

		func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
			guard failure == nil else { return }
			do {
				try handle.write(contentsOf: data)
				hasher.update(data: data)
			} catch {
				failure = error
				dataTask.cancel()
			}
		}

		func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
			if let error = failure ?? error {
				continuation?.resume(throwing: error)
			} else {
				continuation?.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
			}
			continuation = nil
		}
	}
}

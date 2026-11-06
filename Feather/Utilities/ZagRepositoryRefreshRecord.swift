import Foundation

// Per-repository refresh outcomes and the summary shown in Update
// Diagnostics. Foundation only, so it is tested on the host.

struct ZagRepositoryRefreshRecord: Equatable {
	enum Outcome: Equatable {
		/// New payload downloaded, parsed and committed.
		case fresh
		/// Server confirmed the saved copy is current (HTTP 304).
		case notModified
		/// Refresh failed; the last valid copy was kept and used.
		case retainedLastGood(reason: String)
		/// Refresh failed and no valid copy exists: the repository is missing.
		case missing(reason: String)

		var isCurrent: Bool {
			switch self {
			case .fresh, .notModified: return true
			case .retainedLastGood, .missing: return false
			}
		}

		var label: String {
			switch self {
			case .fresh: return "fresh, committed"
			case .notModified: return "unchanged (304), saved copy confirmed"
			case .retainedLastGood(let reason): return "FAILED, last valid copy retained: \(reason)"
			case .missing(let reason): return "FAILED, no valid copy: \(reason)"
			}
		}
	}

	let identifier: String
	let networkPath: String
	let startedAt: Date
	let finishedAt: Date
	let httpStatus: Int?
	let bytes: Int?
	let expectedBytes: Int64?
	let downloadSeconds: Double?
	let parseSeconds: Double?
	let appsBefore: Int?
	let appsAfter: Int?
	let outcome: Outcome

	/// Classifies one repository's refresh from the fetch result and the
	/// fetch service's metric for this attempt.
	static func outcome(
		fetchSucceeded: Bool,
		metricStatus: String?,
		error: String?
	) -> Outcome {
		let reason = error ?? metricStatus ?? "unknown error"
		guard fetchSucceeded else { return .missing(reason: reason) }
		guard let metricStatus else { return .fresh }
		if metricStatus.contains("fallback") { return .retainedLastGood(reason: error ?? "network or parse failure") }
		if metricStatus.contains("304") { return .notModified }
		return .fresh
	}

	/// A repository URL without credentials, query or fragment.
	static func safeIdentifier(_ url: URL) -> String {
		guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			return url.host ?? "repository"
		}
		parts.user = nil
		parts.password = nil
		parts.query = nil
		parts.fragment = nil
		return parts.string ?? (url.host ?? "repository")
	}

	func line() -> String {
		func size(_ value: Int64) -> String {
			ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
		}
		var parts = [identifier]
		parts.append("path \(networkPath)")
		parts.append("HTTP \(httpStatus.map(String.init) ?? "-")")
		if let bytes {
			parts.append(expectedBytes.map { "\(size(Int64(bytes))) of \(size($0))" } ?? size(Int64(bytes)))
		}
		if let downloadSeconds { parts.append(String(format: "download %.2f s", downloadSeconds)) }
		if let parseSeconds { parts.append(String(format: "parse %.2f s", parseSeconds)) }
		parts.append("apps \(appsBefore.map(String.init) ?? "-") → \(appsAfter.map(String.init) ?? "-")")
		parts.append(String(format: "%.2f s total", finishedAt.timeIntervalSince(startedAt)))
		parts.append(outcome.label)
		return "- " + parts.joined(separator: " | ")
	}
}

struct ZagRepositoryRefreshSummary: Equatable {
	let startedAt: Date
	let finishedAt: Date
	let networkPath: String
	let configuredCount: Int
	let records: [ZagRepositoryRefreshRecord]

	var missingCount: Int { records.filter { if case .missing = $0.outcome { return true }; return false }.count + max(0, configuredCount - records.count) }
	var retainedCount: Int { records.filter { if case .retainedLastGood = $0.outcome { return true }; return false }.count }
	var currentCount: Int { records.filter { $0.outcome.isCurrent }.count }

	/// Every configured repository has valid data (fresh or kept).
	var isComplete: Bool { missingCount == 0 }

	/// Whether the update set rests on freshly confirmed data only.
	var freshness: String {
		if !isComplete { return "incomplete (update count not replaced)" }
		if retainedCount == 0 { return "fresh" }
		return "mixed: \(retainedCount) repository(ies) from last valid copy"
	}

	func lines() -> [String] {
		var lines = [
			"Repository refresh: \(currentCount) current, \(retainedCount) kept from last valid copy, " +
			"\(missingCount) missing of \(configuredCount) — " +
			(isComplete ? (retainedCount == 0 ? "complete" : "complete with failures") : "INCOMPLETE"),
			"Refresh network path: \(networkPath)",
		]
		lines += records.sorted { $0.identifier < $1.identifier }.map { $0.line() }
		return lines
	}
}

/// Overlapping refreshes: only a repository snapshot that started at or
/// after the last published one may replace the update set, so a slow
/// earlier refresh can never overwrite a newer result.
struct ZagRefreshOrdering {
	private(set) var latestPublishedStart: Date = .distantPast

	mutating func admit(snapshotStartedAt: Date) -> Bool {
		guard snapshotStartedAt >= latestPublishedStart else { return false }
		latestPublishedStart = snapshotStartedAt
		return true
	}
}

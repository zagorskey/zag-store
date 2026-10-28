import Foundation

/// Resolves legacy fingerprints that accidentally include mutable release notes.
/// A bundle ID or matching name alone is not evidence of a safe variant update.
enum ZagVariantLineageResolver {
	enum Decision: String {
		case exactLegacyIdentity
		case historicalReleaseIdentity
		case stableVariantMarker
		case uniqueSourceAndName
		case differentAppName
		case unknownSource
		case differentSource
		case ambiguousVariant

		var isMatch: Bool {
			switch self {
			case .exactLegacyIdentity, .historicalReleaseIdentity, .stableVariantMarker, .uniqueSourceAndName:
				return true
			case .differentAppName, .unknownSource, .differentSource, .ambiguousVariant:
				return false
			}
		}
	}

	static func normalizedName(_ value: String) -> String {
		value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased()
			.filter { $0.isLetter || $0.isNumber }
	}

	/// Older builds stored the entire release description in a variant key.
	/// Only reuse a distinctive, stable marker; never treat generic release
	/// notes, matching bundle IDs, or app names as a variant fingerprint.
	static func hasStableVariantMarker(
		trackedVariant: String,
		candidateVariant: String
	) -> Bool {
		guard let trackedPipe = trackedVariant.firstIndex(of: "|"),
			let candidatePipe = candidateVariant.firstIndex(of: "|"),
			trackedVariant[..<trackedPipe] == candidateVariant[..<candidatePipe]
		else { return false }
		let tracked = String(trackedVariant[trackedVariant.index(after: trackedPipe)...])
		let candidate = String(candidateVariant[candidateVariant.index(after: candidatePipe)...])
		guard tracked.count >= 12, candidate.count >= 12 else { return false }
		let genericStarts = [
			"thisupdate", "whatsnew", "bugfixes", "newfeatures",
			"improvements", "version", "updatedto", "fullchangelog",
			"highlights", "changesv"
		]
		guard !genericStarts.contains(where: { tracked.hasPrefix($0) }) else { return false }
		// Short mod labels (e.g. "variantnexasc" or
		// "injectedwithsubscriptionunlocked") may appear in longer notes.
		if tracked.count <= 120 && candidate.contains(tracked) {
			return true
		}
		// Publisher-labelled descriptions often include a changing base
		// version immediately after a stable identifying prefix.
		let prefix = String(tracked.prefix { !$0.isNumber })
		return prefix.count >= 20 &&
			!genericStarts.contains(where: { prefix.hasPrefix($0) }) &&
			candidate.hasPrefix(prefix)
	}

	/// Independent, deterministic comparison for multiple accepted candidates.
	/// Never rank a release by source order or publication date alone.
	static func compareRelease(
		version lhsVersion: String, build lhsBuild: String?,
		to rhsVersion: String, build rhsBuild: String?
	) -> ComparisonResult {
		func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
			let l = lhs.split { !$0.isNumber }.compactMap { Int($0) }
			let r = rhs.split { !$0.isNumber }.compactMap { Int($0) }
			if !l.isEmpty && !r.isEmpty {
				for i in 0..<max(l.count, r.count) {
					let a = i < l.count ? l[i] : 0
					let b = i < r.count ? r[i] : 0
					if a != b { return a < b ? .orderedAscending : .orderedDescending }
				}
				return .orderedSame
			}
			return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
		}
		let versions = compare(lhsVersion, rhsVersion)
		guard versions == .orderedSame else { return versions }
		guard let lhsBuild, !lhsBuild.isEmpty, let rhsBuild, !rhsBuild.isEmpty
		else { return .orderedSame }
		return compare(lhsBuild, rhsBuild)
	}

	/// A recent completion hides only the identical release. Legacy rows
	/// with no saved build cannot hide a candidate with a known newer build.
	static func matchesCompletedRelease(
		availableVersion: String,
		availableBuild: String?,
		completedVersion: String,
		completedBuild: String?
	) -> Bool {
		availableVersion == completedVersion &&
			availableBuild == completedBuild
	}

	static func resolve(
		trackedVariant: String,
		trackedAppName: String?,
		trackedRepository: String?,
		candidateAppName: String,
		candidateVariant: String,
		candidateRepositoryAliases: Set<String>,
		sameSourceSameNameCount: Int,
		hasMatchingHistoricalRelease: Bool,
		historicalReleaseMatchCount: Int,
		hasStableVariantEvidence: Bool = false
	) -> Decision {
		if trackedVariant == candidateVariant {
			if let trackedRepository, !trackedRepository.isEmpty,
				!candidateRepositoryAliases.contains(trackedRepository) { return .differentSource }
			return .exactLegacyIdentity
		}
		guard let trackedAppName,
			!normalizedName(trackedAppName).isEmpty,
			normalizedName(trackedAppName) == normalizedName(candidateAppName)
		else { return .differentAppName }
		guard let trackedRepository, !trackedRepository.isEmpty else { return .unknownSource }
		guard candidateRepositoryAliases.contains(trackedRepository) else { return .differentSource }
		if hasMatchingHistoricalRelease && historicalReleaseMatchCount == 1 {
			return .historicalReleaseIdentity
		}
		if hasStableVariantEvidence { return .stableVariantMarker }
		if sameSourceSameNameCount == 1 { return .uniqueSourceAndName }
		return .ambiguousVariant
	}
}

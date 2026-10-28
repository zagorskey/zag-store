import Foundation

@main struct ZagVariantLineageResolverTests {
	static func main() {
		typealias Resolver = ZagVariantLineageResolver
		func decision(
			_ variant: String,
			name: String? = "Regram (No Plugins)",
			origin: String? = "com.fouadraheb.apps-source",
			candidate: String = "Regram (No Plugins)",
			aliases: Set<String> = ["com.fouadraheb.apps-source"],
			count: Int = 1,
			historical: Bool = false,
			historicalCount: Int = 0
		) -> Resolver.Decision {
			Resolver.resolve(
				trackedVariant: "regramnoplugins|oldreleasenotes",
				trackedAppName: name,
				trackedRepository: origin,
				candidateAppName: candidate,
				candidateVariant: variant,
				candidateRepositoryAliases: aliases,
				sameSourceSameNameCount: count,
				hasMatchingHistoricalRelease: historical,
				historicalReleaseMatchCount: historicalCount
			)
		}
		func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
			precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
			print("PASS: \(label)")
		}
		check(decision("regramnoplugins|oldreleasenotes"), .exactLegacyIdentity, "exact identity")
		check(decision("regramnoplugins|newreleasenotes"), .uniqueSourceAndName, "unique successor")
		check(decision("regramnoplugins|newreleasenotes", count: 2, historical: true, historicalCount: 1), .historicalReleaseIdentity, "unique history")
		check(decision("regramnoplugins|newreleasenotes", count: 2), .ambiguousVariant, "ambiguous variants")
		check(decision("regramnoplugins|newreleasenotes", count: 2, historical: true, historicalCount: 2), .ambiguousVariant, "ambiguous history")
		check(decision("regramnoplugins|newreleasenotes", origin: nil), .unknownSource, "missing source")
		check(decision("regramnoplugins|newreleasenotes", aliases: ["different.repo"]), .differentSource, "different source")
		check(decision("regramnoplugins|newreleasenotes", candidate: "RyukGram"), .differentAppName, "different variant name")
		check(decision("regramnoplugins|newreleasenotes", name: "Regram", candidate: "Regram (No Plugins)"), .differentAppName, "different installed name")
		check(decision("regramnoplugins|oldreleasenotes", origin: nil), .exactLegacyIdentity, "legacy exact compatibility")
		check(decision("regramnoplugins|oldreleasenotes", aliases: ["untrusted.repo"]), .differentSource, "exact identity but wrong source")
		func marker(_ tracked: String, _ candidate: String) -> Bool {
			Resolver.hasStableVariantMarker(trackedVariant: tracked, candidateVariant: candidate)
		}
		precondition(marker("soundcloud|variantnexasc", "soundcloud|variantnexascnewbuild"))
		precondition(marker("myfitnesspal|injectedwithsubscriptionunlocked", "myfitnesspal|injectedwithsubscriptionunlockedv2642"))
		precondition(marker("messenger|ipavaultbuildsofmessenger58200richpreviews", "messenger|ipavaultbuildsofmessenger58400fixes"))
		precondition(!marker("regramnoplugins|thisupdatecontainschanges", "regramnoplugins|thisupdatecontainsotherchanges"))
		precondition(!marker("youtube|variant21394youmod200", "youtube|variant21424youmod300"))
		precondition(!marker("youtube|variant21394youmod200", "ytkace|variant21394youmod200"))
		print("PASS: stable variant marker acceptance and collision rejection")
		check(Resolver.resolve(
			trackedVariant: "messenger|ipavaultbuildsofmessenger58200richpreviews",
			trackedAppName: "Messenger",
			trackedRepository: "dev.fastsign.repo",
			candidateAppName: "Messenger",
			candidateVariant: "messenger|ipavaultbuildsofmessenger58400fixes",
			candidateRepositoryAliases: ["dev.fastsign.repo"],
			sameSourceSameNameCount: 40,
			hasMatchingHistoricalRelease: false,
			historicalReleaseMatchCount: 0,
			hasStableVariantEvidence: true
		), .stableVariantMarker, "same source stable marker across many releases")
		check(Resolver.compareRelease(version: "8.83.0", build: nil, to: "8.81.0", build: nil), .orderedDescending, "newest version wins")
		check(Resolver.compareRelease(version: "5.0.8", build: "3", to: "5.0.8", build: "2"), .orderedDescending, "newest build wins")
		check(Resolver.compareRelease(version: "26.40.0", build: nil, to: "26.42.0", build: nil), .orderedAscending, "older release loses")
		check(Resolver.compareRelease(version: "5.0.8", build: nil, to: "5.0.8", build: "2"), .orderedSame, "missing build does not invent newer release")
		precondition(Resolver.matchesCompletedRelease(
			availableVersion: "5.0.8", availableBuild: "2",
			completedVersion: "5.0.8", completedBuild: "2"
		))
		precondition(!Resolver.matchesCompletedRelease(
			availableVersion: "5.0.8", availableBuild: "3",
			completedVersion: "5.0.8", completedBuild: "2"
		))
		precondition(!Resolver.matchesCompletedRelease(
			availableVersion: "5.0.8", availableBuild: "3",
			completedVersion: "5.0.8", completedBuild: nil
		))
		precondition(!Resolver.matchesCompletedRelease(
			availableVersion: "5.0.9", availableBuild: nil,
			completedVersion: "5.0.8", completedBuild: nil
		))
		precondition(Resolver.matchesCompletedRelease(
			availableVersion: "5.0.8", availableBuild: nil,
			completedVersion: "5.0.8", completedBuild: nil
		))
		print("Lineage, release selection and recent-completion tests passed")
	}
}

//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON
import UserNotifications
import CoreData

// MARK: - Class

final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	private let _dataService = NBFetchService()

	var isFinished = true
	@Published private(set) var isRefreshing = false
	@Published var sources: [AltSource: ASRepository] = [:]

	@MainActor
	func fetchSources(
		_ sources: FetchedResults<AltSource>,
		refresh: Bool = false,
		batchSize: Int = 4
	) async {
		guard isFinished else { return }

		let currentSourceURLs = Set(
			sources.compactMap {
				$0.sourceURL?.absoluteString
			}
		)

		self.sources = self.sources.filter { source, _ in
			guard let sourceURL = source.sourceURL?.absoluteString else {
				return false
			}
			return currentSourceURLs.contains(sourceURL)
		}

		if !refresh, sources.allSatisfy({
			self.sources[$0] != nil
		}) {
			// The repository snapshot is already complete. Refresh the device
			// inventory before reconciling updates so shared bundle identifiers
			// are never inferred from stale Signed records.
			reconcileRepositoryOrigins()
			await _refreshUpdatesUsingInstalledInventory(
				repositories: Array(self.sources.values)
			)
			return
		}

		isFinished = false

		self.isRefreshing = true
		UpdateManager.shared.beginRepositoryRefresh()

		defer {
			isFinished = true

			self.isRefreshing = false
			UpdateManager.shared.endRepositoryRefresh()
		}

		let sourcesArray = Array(sources)
		let sourceURLs = sourcesArray.compactMap { source -> (AltSource, URL)? in
			guard let url = source.sourceURL else { return nil }
			return (source, url)
		}

		// Build the next repository state off-screen. Child tasks traffic only
		// in URLs and repository values; NSManagedObject instances never cross
		// a task boundary.
		var refreshedSources: [AltSource: ASRepository] = refresh
			? [:]
			: self.sources

		for startIndex in stride(
			from: 0,
			to: sourceURLs.count,
			by: batchSize
		) {
			let endIndex = min(
				startIndex + batchSize,
				sourceURLs.count
			)

			let batch = sourceURLs[startIndex..<endIndex]
			let batchURLs = batch.map { $0.1 }

			let batchResults = await withTaskGroup(
				of: (URL, ASRepository?).self,
				returning: [URL: ASRepository].self
			) { group in
				for url in batchURLs {
					group.addTask {
						await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) {
								(result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (url, repo))
								case .failure:
									continuation.resume(returning: (url, nil))
								}
							}
						}
					}
				}

				var results = [URL: ASRepository]()
				for await (url, repo) in group {
					if let repo {
						results[url] = repo
					}
				}
				return results
			}

			let savedSourceURLs = Set(
				Storage.shared.getSources().compactMap {
					$0.sourceURL?.absoluteString
				}
			)

			for (source, url) in batch {
				guard
					savedSourceURLs.contains(url.absoluteString),
					let repo = batchResults[url]
				else {
					continue
				}
				refreshedSources[source] = repo
			}

			refreshedSources = refreshedSources.filter { source, _ in
				guard let url = source.sourceURL?.absoluteString else {
					return false
				}
				return savedSourceURLs.contains(url)
			}
		}

		let completedSources = refreshedSources
		let completedRepositories = Array(completedSources.values)

		// Publish the repository snapshot and its derived update state as
		// one completed refresh. Until this point the previous Updates
		// pill/count and app-icon badge remain untouched.
		self.sources = completedSources
		reconcileRepositoryOrigins()
		await _refreshUpdatesUsingInstalledInventory(
			repositories: completedRepositories
		)
	}

	@MainActor
	private func _refreshUpdatesUsingInstalledInventory(
		repositories: [ASRepository]
	) async {
		let pairingCore = ZagRPPairingCore.shared

		// If a valid inventory is already loaded, use it immediately. A full
		// source refresh still requests a fresh inventory below when possible.
		if case .refreshing = pairingCore.installedAppsState {
			print("[Zag Store Updates] Installed-app inventory already refreshing; keeping previous update snapshot")
			ZagLogger.shared.warning("Updates", "Installed-app inventory already refreshing; keeping previous update snapshot")
			return
		}

		do {
			let result: Result<Set<String>, Error> = await withCheckedContinuation { continuation in
				do {
					try pairingCore.refreshInstalledApps { result in
						continuation.resume(returning: result)
					}
				} catch {
					continuation.resume(returning: .failure(error))
				}
			}

			switch result {
			case .success:
				UpdateManager.shared.refresh(repositories: repositories)
			case .failure(let error):
				if case .loaded = pairingCore.installedAppsState {
					print("[Zag Store Updates] Live inventory refresh failed; using last loaded inventory: \(error.localizedDescription)")
					ZagLogger.shared.warning("Updates", "Live inventory refresh failed; using last loaded inventory: \(error.localizedDescription)")
					UpdateManager.shared.refresh(repositories: repositories)
				} else {
					print("[Zag Store Updates] Live inventory unavailable; keeping previous update snapshot: \(error.localizedDescription)")
				}
			}
		} 
	}

	// MARK: - Repository Origin Provenance

	@MainActor
	func reconcileRepositoryOrigins() {
		let defaults = UserDefaults.standard
		var origins = defaults.dictionary(
			forKey: "zagStore.repositoryOrigins"
		) as? [String: String] ?? [:]
		var icons = defaults.dictionary(
			forKey: "zagStore.repositoryOriginIcons"
		) as? [String: String] ?? [:]

		var repositoriesByBundleID: [String: [(AltSource, ASRepository)]] = [:]
		for (storedSource, repository) in sources {
			for app in repository.apps {
				guard let bundleID = app.id, !bundleID.isEmpty else { continue }
				repositoriesByBundleID[bundleID, default: []].append(
					(storedSource, repository)
				)
			}
		}

		var changedOrigins = false
		var changedIcons = false

		for (bundleID, matches) in repositoriesByBundleID {
			if origins[bundleID] == nil, matches.count == 1,
			   let match = matches.first {
				let repository = match.1
				let stableKey =
					match.0.sourceURL?.absoluteString ??
					repository.id ??
					repository.website?.absoluteString ??
					repository.name
				if let stableKey, !stableKey.isEmpty {
					origins[bundleID] = stableKey
					changedOrigins = true
				}
			}

			guard let origin = origins[bundleID] else { continue }
			if let match = matches.first(where: { storedSource, repository in
				storedSource.sourceURL?.absoluteString == origin ||
				repository.id == origin ||
				repository.website?.absoluteString == origin ||
				repository.name == origin
			}), let icon = match.1.currentIconURL?.absoluteString,
			   icons[bundleID] != icon {
				icons[bundleID] = icon
				changedIcons = true
			}
		}

		if changedOrigins {
			defaults.set(origins, forKey: "zagStore.repositoryOrigins")
		}
		if changedIcons {
			defaults.set(icons, forKey: "zagStore.repositoryOriginIcons")
		}
	}

	// MARK: - Source Cache Management

	@MainActor
	func removeSource(_ source: AltSource) {
		let removedURL = source.sourceURL?.absoluteString

		sources = sources.filter { cachedSource, _ in
			if let removedURL {
				return cachedSource.sourceURL?.absoluteString != removedURL
			}

			return cachedSource != source
		}

		UpdateManager.shared.refresh(
			repositories: Array(sources.values)
		)

		print(
			"[Zag Store Sources] Removed source from cache: " +
				(removedURL ?? "unknown")
		)
	}
}


// MARK: - Petar: Repository Update Detection

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()

	struct LegacyVariantCandidate: Identifiable, Hashable {
		let bundleID: String
		let appName: String
		let repositoryName: String
		let version: String?
		let variantDescription: String?

		var id: String {
			bundleID + "|" + appName + "|" + repositoryName + "|" +
			(version ?? "") + "|" + (variantDescription ?? "")
		}

		var displayName: String {
			guard let variantDescription, !variantDescription.isEmpty else {
				return appName
			}
			return appName + " — " + variantDescription
		}

		var variantIdentity: String {
			UpdateManager.variantIdentity(
				appName: appName,
				variantDescription: variantDescription
			)
		}
	}

	struct AvailableUpdate: Identifiable {
		let app: ASRepository.App
		let source: ASRepository
		let installedVersion: String
		let availableVersion: String
		let installedBuild: String?
		let availableBuild: String?

		var id: String {
			app.id ?? app.currentUniqueId
		}
	}

	private struct LocalApp {
		let name: String
		let identifier: String
		let version: String
		let build: String?
	}

	@Published private(set) var updates: [AvailableUpdate] = []
	@Published private(set) var persistedUpdateCount: Int
	@Published private(set) var diagnosticsReport = "Run a repository refresh to capture update diagnostics."
	@Published private(set) var legacyVariantCandidates: [LegacyVariantCandidate] = []

	private static let persistedUpdateCountKey =
		"ZagStore.persistedUpdateCount"
	static let updateNotificationsEnabledKey =
		"ZagStore.updateNotificationsEnabled"
	private static let notifiedUpdateSignaturesKey =
		"ZagStore.notifiedUpdateSignatures"

	var updateCount: Int {
		updates.isEmpty ? persistedUpdateCount : updates.count
	}

	var hasVisibleUpdates: Bool {
		updateCount > 0
	}

	private var repositoryRefreshDepth = 0

	private init() {
		persistedUpdateCount = UserDefaults.standard.integer(
			forKey: Self.persistedUpdateCountKey
		)
	}

	func beginRepositoryRefresh() {
		repositoryRefreshDepth += 1
	}

	func endRepositoryRefresh() {
		repositoryRefreshDepth = max(0, repositoryRefreshDepth - 1)
	}

	var isRepositoryRefreshInProgress: Bool {
		repositoryRefreshDepth > 0
	}


	// MARK: - Zag Store App Icon Badge

	func requestBadgePermission() async {
		do {
			let granted = try await UNUserNotificationCenter.current()
				.requestAuthorization(options: [.badge, .alert, .sound])

			print(
				"[Zag Store Badge] Permission " +
					(granted ? "granted" : "not granted")
			)

			if granted {
				await syncAppIconBadge()
			}
		} catch {
			print(
				"[Zag Store Badge] Permission error: " +
					error.localizedDescription
			)
		}
	}

	func requestUpdateNotificationPermission() async -> Bool {
		do {
			return try await UNUserNotificationCenter.current()
				.requestAuthorization(options: [.badge, .alert, .sound])
		} catch {
			print("[Zag Store Notifications] Permission error: " + error.localizedDescription)
			ZagLogger.shared.error("Notifications", "Permission error: \(error.localizedDescription)")
			return false
		}
	}

	private func notifyAboutNewUpdatesIfNeeded(_ updates: [AvailableUpdate]) {
		guard UserDefaults.standard.bool(forKey: Self.updateNotificationsEnabledKey) else {
			return
		}

		let signatures = Set(updates.map {
			($0.app.id ?? $0.app.currentUniqueId) + "|" + $0.availableVersion
		})
		let defaults = UserDefaults.standard
		let previous = Set(defaults.stringArray(forKey: Self.notifiedUpdateSignaturesKey) ?? [])
		let newSignatures = signatures.subtracting(previous)

		// Always update the snapshot. If an update disappears and later returns,
		// it can notify again rather than remaining suppressed forever.
		defaults.set(Array(signatures), forKey: Self.notifiedUpdateSignaturesKey)
		guard !newSignatures.isEmpty else { return }

		let newUpdates = updates.filter {
			newSignatures.contains(($0.app.id ?? $0.app.currentUniqueId) + "|" + $0.availableVersion)
		}

		let content = UNMutableNotificationContent()
		content.sound = .default
		if newUpdates.count == 1, let update = newUpdates.first {
			content.title = "Update Available"
			content.body = "\(update.app.currentName) \(update.availableVersion) is available in Zag Store."
		} else {
			content.title = "Updates Available"
			content.body = "\(newUpdates.count) app updates are available in Zag Store."
		}

		let request = UNNotificationRequest(
			identifier: "ZagStore.update-notification." + UUID().uuidString,
			content: content,
			trigger: nil
		)
		UNUserNotificationCenter.current().add(request) { error in
			if let error {
				print("[Zag Store Notifications] Delivery failed: " + error.localizedDescription)
				ZagLogger.shared.error("Notifications", "Delivery failed: \(error.localizedDescription)")
			}
		}
	}

	func syncAppIconBadge() async {
		do {
			try await UNUserNotificationCenter.current()
				.setBadgeCount(updateCount)

			print(
				"[Zag Store Badge] App icon badge = \(updateCount)"
			)
		} catch {
			print(
				"[Zag Store Badge] Failed to set badge: " +
					error.localizedDescription
			)
		}
	}


	// MARK: - Global Update Check

	func refresh(repositories: [ASRepository]) {
		let context = Storage.shared.context

		do {
			let signedRequest = Signed.fetchRequest()
			let importedRequest = Imported.fetchRequest()

			let signedApps = try context.fetch(signedRequest)
			let importedApps = try context.fetch(importedRequest)

			print(
				"[Zag Store Updates] Global check: " +
					"\(repositories.count) repositories, " +
					"\(signedApps.count) signed, " +
					"\(importedApps.count) imported"
			)

			refresh(
				repositories: repositories,
				signedApps: signedApps,
				importedApps: importedApps
			)
		} catch {
			// A transient Core Data failure must not erase the last known-good
			// update snapshot. Keep it authoritative until a later successful
			// reconciliation can replace it.
			print(
				"[Zag Store Updates] Core Data fetch failed: " +
					error.localizedDescription +
					" — keeping previous update state"
			)
		}
	}


	// MARK: - Update Detection

	func refresh(
		repositories: [ASRepository],
		signedApps: [Signed],
		importedApps: [Imported]
	) {
		var localApps: [LocalApp] = []
		let persistedAppOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]

		let pairingCore = ZagRPPairingCore.shared
		let deviceInventory = pairingCore.installedApps

		if case .loaded = pairingCore.installedAppsState {
			// Device inventory is authoritative for both installed state and
			// the version/build actually present on the iPhone. A Signed record
			// may represent a different IPA version and must not override it.
			for installed in deviceInventory.values {
				guard !installed.version.isEmpty else { continue }

				let bundleSignedApps = signedApps.filter {
					$0.identifier == installed.bundleID
				}
				let matchingSignedApps = bundleSignedApps.filter {
					$0.version == installed.version
				}

				let signedName: String? = {
					if !installed.build.isEmpty {
						let buildMatches = matchingSignedApps.filter {
							_buildVersion(for: $0) == installed.build
						}
						let buildNames = Set(
							buildMatches.compactMap { $0.name }.filter { !$0.isEmpty }
						)
						if buildNames.count == 1 {
							return buildNames.first
						}
					}

					let versionNames = Set(
						matchingSignedApps.compactMap { $0.name }.filter { !$0.isEmpty }
					)
					if versionNames.count == 1 {
						return versionNames.first
					}

					// If only one signed identity exists for this bundle ID, it is
					// stronger evidence than repository entries that merely reuse the ID.
					let bundleNames = Set(
						bundleSignedApps.compactMap { $0.name }.filter { !$0.isEmpty }
					)
					return bundleNames.count == 1 ? bundleNames.first : nil
				}()

				let repositoryMatches = repositories
					.flatMap { $0.apps }
					.filter { $0.id == installed.bundleID }
				let repositoryNames = Set(
					repositoryMatches.map { $0.currentName }.filter { !$0.isEmpty }
				)
				let repositoryName = repositoryNames.count == 1
					? repositoryNames.first
					: nil

				guard let installedName = persistedAppOrigins[installed.bundleID] ?? signedName ?? repositoryName else {
					print(
						"[Zag Store Updates] AMBIGUOUS INSTALLED IDENTITY: " +
						"id=\(installed.bundleID) — skipping cross-variant update matching"
					)
					ZagLogger.shared.warning(
						"Updates",
						"Ambiguous installed identity; skipped cross-variant matching | id=\(installed.bundleID)"
					)
					continue
				}

				_addLocalApp(
					name: installedName,
					identifier: installed.bundleID,
					version: installed.version,
					build: installed.build.isEmpty ? nil : installed.build,
					to: &localApps
				)
			}

			print(
				"[Zag Store Updates] Using authoritative device inventory: " +
					"\(localApps.count) versioned app(s)"
			)
		} else {
			// Preserve the previous behavior until the first successful device
			// inventory is available. This keeps background/source refreshes
			// functional when RPPairing has not established a snapshot yet.
			for app in signedApps {
				_addLocalApp(
					name: app.name,
					identifier: app.identifier,
					version: app.version,
					build: _buildVersion(for: app),
					to: &localApps
				)
			}

			print(
				"[Zag Store Updates] Device inventory unavailable; " +
					"using Signed fallback: \(localApps.count) app(s)"
			)
		}

		// Imported packages are never installed-state evidence.

		print(
			"[Zag Store Updates] Local identities: \(localApps.count)"
		)
		ZagLogger.shared.info("Updates", "Repository reconciliation running with \(localApps.count) local identities and \(repositories.count) repositories")

		for localApp in localApps {
			print(
				"[Zag Store Updates] LOCAL: " +
					"\(localApp.name) | " +
					"id=\(localApp.identifier) | " +
					"version=\(localApp.version)"
			)
		}

		var foundUpdates: [AvailableUpdate] = []
		var seenLocalApps = Set<String>()

		let recordedOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryOrigins"
		) as? [String: String] ?? [:]
		let recordedAppOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		let recordedVariantOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]

		if case .loaded = pairingCore.installedAppsState {
			var adoptionCandidates: [LegacyVariantCandidate] = []
			for installed in deviceInventory.values {
				guard recordedAppOrigins[installed.bundleID] == nil else { continue }
				let matches = repositories.flatMap { repository in
					repository.apps.compactMap { candidate -> LegacyVariantCandidate? in
						guard candidate.id == installed.bundleID else { return nil }
						let releaseDescription =
							candidate.currentAppVersion?.localizedDescription ??
							candidate.versionDescription ??
							candidate.currentDescription
						return LegacyVariantCandidate(
							bundleID: installed.bundleID,
							appName: candidate.currentName,
							repositoryName: repository.name ?? "Unknown Repository",
							version: candidate.currentVersion,
							variantDescription: releaseDescription?
								.trimmingCharacters(in: .whitespacesAndNewlines)
						)
					}
				}
				let uniqueNames = Set(matches.map { _normalizedAppName($0.appName) })
				guard uniqueNames.count > 1 else { continue }
				var seenCandidates = Set<String>()
				for candidate in matches.sorted(by: {
					if $0.appName == $1.appName { return $0.repositoryName < $1.repositoryName }
					return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
				}) {
					let key = _normalizedAppName(candidate.appName) + "|" +
						(candidate.variantDescription ?? "").lowercased()
					if seenCandidates.insert(key).inserted {
						adoptionCandidates.append(candidate)
					}
				}
			}
			legacyVariantCandidates = adoptionCandidates
		} else {
			legacyVariantCandidates = []
		}

		var repositoryOriginAliases: [String: Set<String>] = [:]
		for (storedSource, candidateRepository) in SourcesViewModel.shared.sources {
			let aliases = [
				storedSource.sourceURL?.absoluteString,
				candidateRepository.id,
				candidateRepository.website?.absoluteString,
				candidateRepository.name
			].compactMap { $0 }.filter { !$0.isEmpty }

			let aliasSet = Set(aliases)
			for alias in aliases {
				repositoryOriginAliases[alias, default: []].formUnion(aliasSet)
			}
		}

		let localAppsByIdentifier = Dictionary(grouping: localApps) { $0.identifier }
		var repositoryAppNamesByIdentifier: [String: Set<String>] = [:]
		for repository in repositories {
			for candidate in repository.apps {
				guard let identifier = candidate.id, !identifier.isEmpty else { continue }
			repositoryAppNamesByIdentifier[identifier, default: []].insert(
					_normalizedAppName(candidate.currentName)
				)
			}
		}

		for repository in repositories {
			for app in repository.apps {
				guard
					let identifier = app.id,
					!identifier.isEmpty,
					let availableVersion = app.currentVersion,
					!availableVersion.isEmpty
				else {
					continue
				}

				// A shared bundle identifier is not enough to establish update
				// lineage. Tweaked variants (for example Regram/RyukGram) can
				// deliberately retain the original App Store bundle identifier.
				// When Zag Store knows which repository supplied the installed
				// package, only that repository may offer its updates.
				guard _repositoryMatchesRecordedOrigin(
					identifier: identifier,
					repository: repository,
					origins: recordedOrigins,
					repositoryOriginAliases: repositoryOriginAliases
				) else {
					print(
						"[Zag Store Updates] IGNORED SOURCE COLLISION: " +
						"id=\(identifier) | repo=\(repository.name ?? "unknown")"
					)
					ZagLogger.shared.debug(
						"Updates",
						"Ignored source collision | id=\(identifier) | repo=\(repository.name ?? "unknown")"
					)
					continue
				}

				guard let candidates = localAppsByIdentifier[identifier],
					!candidates.isEmpty else {
					continue
				}

				let recordedAppOrigin = recordedAppOrigins[identifier]
				if recordedAppOrigin == nil,
				   (repositoryAppNamesByIdentifier[identifier]?.count ?? 0) > 1 {
					print(
						"[Zag Store Updates] UNTRACKED AMBIGUOUS VARIANT: " +
						"id=\(identifier) — exact app lineage required"
					)
					ZagLogger.shared.warning(
						"Updates",
						"Untracked ambiguous variant; exact lineage required | id=\(identifier)"
					)
					continue
				}
				if let recordedAppOrigin,
				   _normalizedAppName(recordedAppOrigin) != _normalizedAppName(app.currentName) {
					print(
						"[Zag Store Updates] IGNORED VARIANT COLLISION: " +
						"id=\(identifier) | tracked=\(recordedAppOrigin) | candidate=\(app.currentName)"
					)
					ZagLogger.shared.debug(
						"Updates",
						"Ignored variant collision | id=\(identifier) | tracked=\(recordedAppOrigin) | candidate=\(app.currentName)"
					)
					continue
				}

				if let recordedVariantOrigin = recordedVariantOrigins[identifier] {
					let candidateVariantIdentity = Self.variantIdentity(for: app)
					guard recordedVariantOrigin == candidateVariantIdentity else {
						print(
							"[Zag Store Updates] IGNORED VARIANT LINEAGE: " +
							"id=\(identifier) | tracked=\(recordedVariantOrigin) | " +
							"candidate=\(candidateVariantIdentity)"
						)
						ZagLogger.shared.debug(
							"Updates",
							"Ignored variant lineage | id=\(identifier) | tracked=\(recordedVariantOrigin) | candidate=\(candidateVariantIdentity)"
						)
						continue
					}
				}

				for localApp in candidates {
					let identityMatches = recordedAppOrigin != nil
						? true
						: _sameAppIdentity(
							installedName: localApp.name,
							repositoryName: app.currentName
						)
					guard identityMatches else {
						print(
							"[Zag Store Updates] " +
								"IGNORED COLLISION: " +
								"installed=\(localApp.name) | " +
								"candidate=\(app.currentName) | " +
								"id=\(identifier) | " +
								"repo=\(repository.name ?? "unknown")"
						)
						continue
					}

					let availableBuild = app.currentAppVersion?.build
					guard _isRepositoryReleaseNewer(
						availableVersion: availableVersion,
						availableBuild: availableBuild,
						installedVersion: localApp.version,
						installedBuild: localApp.build
					) else {
						continue
					}

					let localKey =
						identifier.lowercased() + "|" +
						_normalizedAppName(localApp.name)

					guard
						seenLocalApps.insert(localKey).inserted
					else {
						continue
					}

					foundUpdates.append(
						AvailableUpdate(
							app: app,
							source: repository,
							installedVersion: localApp.version,
							availableVersion: availableVersion,
							installedBuild: localApp.build,
							availableBuild: availableBuild
						)
					)

					break
				}
			}
		}

		var diagnosticLines: [String] = []
		diagnosticLines.append("=== Zag Store Update Diagnostics ===")
		diagnosticLines.append("Raw device inventory:")
		for installed in deviceInventory.values.sorted(by: { $0.bundleID < $1.bundleID }) {
			let origin = recordedOrigins[installed.bundleID] ?? "<none>"
			let appOrigin = recordedAppOrigins[installed.bundleID] ?? "<none>"
			diagnosticLines.append("- id=\(installed.bundleID) | version=\(installed.version) | build=\(installed.build.isEmpty ? "<none>" : installed.build) | origin=\(origin) | appOrigin=\(appOrigin)")
			let matchingSigned = signedApps.filter { $0.identifier == installed.bundleID }
			if matchingSigned.isEmpty {
				diagnosticLines.append("  signed: <none>")
			} else {
				let identities = Set(matchingSigned.map { signed in
					"\(signed.name ?? "<unnamed>") | version=\(signed.version ?? "<none>") | build=\(_buildVersion(for: signed) ?? "<none>")"
				})
				for identity in identities.sorted() {
					diagnosticLines.append("  signed: \(identity)")
				}
			}

			let repoIdentities = Set(repositories.flatMap { repository in
				repository.apps.compactMap { candidate -> String? in
					guard candidate.id == installed.bundleID else { return nil }
					return "\(candidate.currentName) | repo=\(repository.name ?? "<unknown>")"
				}
			})
			for identity in repoIdentities.sorted() {
				diagnosticLines.append("  repo: \(identity)")
			}

			let exactReleaseMatches = repositories.flatMap { repository in
				repository.apps.compactMap { candidate -> String? in
					guard candidate.id == installed.bundleID else { return nil }
					let releases = candidate.versions ?? []
					let exact = releases.contains { release in
						guard release.version == installed.version else { return false }
						if installed.build.isEmpty { return true }
						guard let build = release.build, !build.isEmpty else { return false }
						return build == installed.build
					}
					guard exact else { return nil }
					return "\(candidate.currentName) | repo=\(repository.name ?? "<unknown>")"
				}
			}
			if !exactReleaseMatches.isEmpty {
				diagnosticLines.append("  EXACT INSTALLED RELEASE MATCHES:")
				for match in Set(exactReleaseMatches).sorted() {
					diagnosticLines.append("    • \(match)")
				}
			}
		}

		diagnosticLines.append("")
		diagnosticLines.append("Resolved installed identities:")
		for localApp in localApps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
			diagnosticLines.append("- \(localApp.name) | id=\(localApp.identifier) | version=\(localApp.version) | build=\(localApp.build ?? "<none>")")
		}

		diagnosticLines.append("")
		diagnosticLines.append("Accepted updates:")
		if foundUpdates.isEmpty {
			diagnosticLines.append("- <none>")
		} else {
			for update in foundUpdates {
				diagnosticLines.append("- \(update.app.currentName) | id=\(update.app.id ?? "<none>") | \(update.installedVersion) -> \(update.availableVersion) | repo=\(update.source.name ?? "<unknown>")")
			}
		}
		diagnosticsReport = diagnosticLines.joined(separator: "\n")

		updates = foundUpdates.sorted { lhs, rhs in
			let lhsDate = lhs.app.currentDate?.date ?? .distantPast
			let rhsDate = rhs.app.currentDate?.date ?? .distantPast

			if lhsDate != rhsDate {
				return lhsDate > rhsDate
			}

			return lhs.app.currentName.localizedCaseInsensitiveCompare(
				rhs.app.currentName
			) == .orderedAscending
		}

		persistedUpdateCount = updates.count
		UserDefaults.standard.set(
			persistedUpdateCount,
			forKey: Self.persistedUpdateCountKey
		)

		notifyAboutNewUpdatesIfNeeded(updates)

		Task {
			await syncAppIconBadge()
		}

		print(
			"[Zag Store Updates] Check complete: " +
				"\(updates.count) update(s)"
		)

		for update in updates {
			print(
				"[Zag Store Updates] MATCH: " +
					"\(update.app.currentName) | " +
					"id=\(update.app.id ?? "nil") | " +
					"\(update.installedVersion) -> " +
					"\(update.availableVersion) | " +
					"repo=\(update.source.name ?? "unknown")"
			)
			ZagLogger.shared.info(
				"Updates",
				"Matched update | \(update.app.currentName) | id=\(update.app.id ?? "nil") | \(update.installedVersion) -> \(update.availableVersion) | repo=\(update.source.name ?? "unknown")"
			)
		}
	}


	// MARK: - Update Lookup

	func update(
		for identifier: String?
	) -> AvailableUpdate? {
		guard let identifier else {
			return nil
		}

		return updates.first {
			$0.app.id == identifier
		}
	}

	func hasUpdate(
		for identifier: String?
	) -> Bool {
		update(for: identifier) != nil
	}


	// MARK: - Local App Helpers

	private func _addLocalApp(
		name: String?,
		identifier: String?,
		version: String?,
		build: String? = nil,
		to apps: inout [LocalApp]
	) {
		guard
			let name,
			!name.isEmpty,
			let identifier,
			!identifier.isEmpty,
			let version,
			!version.isEmpty
		else {
			return
		}

		let normalizedName = _normalizedAppName(name)

		if let index = apps.firstIndex(where: {
			$0.identifier == identifier &&
				_normalizedAppName($0.name) == normalizedName
		}) {
			if _compareVersions(
				version,
				apps[index].version
			) == .orderedDescending {
				apps[index] = LocalApp(
					name: name,
					identifier: identifier,
					version: version,
					build: build
				)
			}
		} else {
			apps.append(
				LocalApp(
					name: name,
					identifier: identifier,
					version: version,
					build: build
				)
			)
		}
	}


	// MARK: - App Identity

	private func _sameAppIdentity(
		installedName: String,
		repositoryName: String
	) -> Bool {
		_normalizedAppName(installedName) ==
			_normalizedAppName(repositoryName)
	}

	func adoptLegacyVariant(_ candidate: LegacyVariantCandidate) {
		var appOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		appOrigins[candidate.bundleID] = candidate.appName
		UserDefaults.standard.set(appOrigins, forKey: "zagStore.repositoryAppOrigins")
		var variantOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]
		variantOrigins[candidate.bundleID] = candidate.variantIdentity
		UserDefaults.standard.set(variantOrigins, forKey: "zagStore.repositoryVariantOrigins")
		refresh(repositories: SourcesViewModel.shared.sources.map { $0.1 })
	}

	func clearLegacyVariantAdoption(bundleID: String) {
		var appOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		appOrigins.removeValue(forKey: bundleID)
		UserDefaults.standard.set(appOrigins, forKey: "zagStore.repositoryAppOrigins")
		var variantOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]
		variantOrigins.removeValue(forKey: bundleID)
		UserDefaults.standard.set(variantOrigins, forKey: "zagStore.repositoryVariantOrigins")
		refresh(repositories: SourcesViewModel.shared.sources.map { $0.1 })
	}

	static func variantIdentity(for app: ASRepository.App) -> String {
		let description =
			app.currentAppVersion?.localizedDescription ??
			app.versionDescription ??
			app.currentDescription
		return variantIdentity(
			appName: app.currentName,
			variantDescription: description
		)
	}

	nonisolated static func variantIdentity(
		appName: String,
		variantDescription: String?
	) -> String {
		func normalized(_ value: String) -> String {
			value
				.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
				.lowercased()
				.filter { $0.isLetter || $0.isNumber }
		}
		return normalized(appName) + "|" + normalized(variantDescription ?? "")
	}

	private func _repositoryMatchesRecordedOrigin(
		identifier: String,
		repository: ASRepository,
		origins: [String: String],
		repositoryOriginAliases: [String: Set<String>]
	) -> Bool {
		guard
			let origin = origins[identifier],
			!origin.isEmpty
		else {
			return true
		}

		let candidateAliases = Set([
			repository.id,
			repository.website?.absoluteString,
			repository.name
		].compactMap { $0 }.filter { !$0.isEmpty })

		if candidateAliases.contains(origin) {
			return true
		}

		if let aliases = repositoryOriginAliases[origin] {
			return !candidateAliases.isDisjoint(with: aliases)
		}

		// A stale origin must not permanently hide updates if its repository
		// has been removed. Only reject when the recorded origin still resolves
		// to a different active repository.
		return true
	}

	private func _normalizedAppName(
		_ name: String
	) -> String {
		name
			.folding(
				options: [
					.caseInsensitive,
					.diacriticInsensitive
				],
				locale: .current
			)
			.lowercased()
			.filter {
				$0.isLetter || $0.isNumber
			}
	}


	private func _buildVersion(for app: Signed) -> String? {
		guard
			let appURL = Storage.shared.getAppDirectory(for: app),
			let bundle = Bundle(url: appURL)
		else {
			return nil
		}

		return bundle.object(
			forInfoDictionaryKey: "CFBundleVersion"
		) as? String
	}

	private func _isRepositoryReleaseNewer(
		availableVersion: String,
		availableBuild: String?,
		installedVersion: String,
		installedBuild: String?
	) -> Bool {
		// Some repositories expose rolling/nightly artifacts with labels such
		// as "Build 813" in the version field. That is a build channel, not a
		// semantic successor to an installed release such as 1.3.2. Comparing
		// 813 against 1.3.2 numerically creates a permanent false update.
		if _isBuildOnlyVersion(availableVersion) &&
			!_isBuildOnlyVersion(installedVersion) {
			return false
		}

		let versionResult = _compareVersions(
			availableVersion,
			installedVersion
		)

		if versionResult == .orderedDescending { return true }
		if versionResult == .orderedAscending { return false }

		guard
			let availableBuild,
			!availableBuild.isEmpty,
			let installedBuild,
			!installedBuild.isEmpty
		else {
			return false
		}

		return _compareVersions(
			availableBuild,
			installedBuild
		) == .orderedDescending
	}


	// MARK: - Version Comparison

	private func _isBuildOnlyVersion(_ value: String) -> Bool {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return false }

		let lowercased = trimmed.lowercased()
		guard lowercased.hasPrefix("build") else { return false }

		let suffix = lowercased.dropFirst("build".count)
		let digits = suffix.filter(\.isNumber)
		return !digits.isEmpty &&
			suffix.allSatisfy { $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "#" }
	}

	private func _compareVersions(
		_ lhs: String,
		_ rhs: String
	) -> ComparisonResult {
		let lhsParts = _numericVersionParts(lhs)
		let rhsParts = _numericVersionParts(rhs)

		// Repository version strings sometimes carry build/channel prefixes
		// (for example "HV-4.6.4"). Compare their numeric version components
		// rather than letting the prefix make an older build look newer.
		if !lhsParts.isEmpty, !rhsParts.isEmpty {
			let count = max(lhsParts.count, rhsParts.count)

			for index in 0..<count {
				let left = index < lhsParts.count ? lhsParts[index] : 0
				let right = index < rhsParts.count ? rhsParts[index] : 0

				if left != right {
					return left < right ? .orderedAscending : .orderedDescending
				}
			}

			return .orderedSame
		}

		return lhs.compare(
			rhs,
			options: [
				.numeric,
				.caseInsensitive
			]
		)
	}

	private func _numericVersionParts(_ version: String) -> [Int] {
		version
			.split { !$0.isNumber }
			.compactMap { Int($0) }
	}
}

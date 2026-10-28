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
	@Published private(set) var refreshingSourceURLs: Set<String> = []
	@Published var sources: [AltSource: ASRepository] = [:]

	// Non-observable row summaries: assigned before each live repository
	// publication so reading them never triggers an extra SwiftUI update.
	private var rowMetadataByURL: [String: ZagSourceRowMetadata] = [:]

	@MainActor
	func rowMetadata(for source: AltSource) -> ZagSourceRowMetadata? {
		guard let url = source.sourceURL?.absoluteString else { return nil }
		return rowMetadataByURL[url]
	}

	@MainActor
	func fetchSources(
		_ sources: FetchedResults<AltSource>,
		refresh: Bool = false,
		batchSize: Int = 4,
		diagnosticSkipReconciliation: Bool = false
	) async {
		guard isFinished else { return }
		let diagnosticStart = CFAbsoluteTimeGetCurrent()
		let metricStart = ZagPerformanceMonitor.now()
		print("[Zag Refresh Diagnostic] Begin — skip reconciliation: \(diagnosticSkipReconciliation)")

		let currentSourceURLs = Set(
			sources.compactMap {
				$0.sourceURL?.absoluteString
			}
		)
		_dataService.retainCachedRepositories(
			for: Set(sources.compactMap { $0.sourceURL })
		)
		rowMetadataByURL = rowMetadataByURL.filter {
			currentSourceURLs.contains($0.key)
		}

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

		let sourcesArray = Array(sources)
		let sourceURLs = sourcesArray.compactMap { source -> (AltSource, URL)? in
			guard let url = source.sourceURL else { return nil }
			return (source, url)
		}

		isFinished = false

		self.isRefreshing = true
		self.refreshingSourceURLs = Set(sourceURLs.map { $0.1.absoluteString })
		UpdateManager.shared.beginRepositoryRefresh()

		defer {
			isFinished = true

			self.isRefreshing = false
			self.refreshingSourceURLs.removeAll()
			UpdateManager.shared.endRepositoryRefresh()
		}

		// Build the next repository state off-screen. Child tasks traffic only
		// in URLs and repository values; NSManagedObject instances never cross
		// a task boundary.
		// Keep the last known-good snapshot visible while refreshing. Each
		// repository replaces its own snapshot as soon as it finishes.
		var refreshedSources: [AltSource: ASRepository] = self.sources

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

			await withTaskGroup(of: (URL, ASRepository?, ZagSourceRowMetadata?).self) { group in
				for url in batchURLs {
					group.addTask {
						let startedAt = CFAbsoluteTimeGetCurrent()
						let host = url.host ?? url.absoluteString
						print("[Zag Store Sources] Fetch started: \(host)")

						let fetched: (URL, ASRepository?) = await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) {
								(result: RepositoryDataHandler) in
								let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
								switch result {
								case .success(let repo):
									print(
										"[Zag Store Sources] Fetch+decode finished: " +
										"\(host) — \(repo.apps.count) apps — " +
										String(format: "%.3fs", elapsed)
									)
									continuation.resume(returning: (url, repo))
								case .failure(let error):
									print(
										"[Zag Store Sources] Fetch failed: " +
										"\(host) — " +
										String(format: "%.3fs", elapsed) +
										" — \(error.localizedDescription)"
									)
									continuation.resume(returning: (url, nil))
								}
							}
						}
						// Keep O(appCount) metadata scans on this fetch worker.
						// Never repeat them during 380ms refresh-dot updates.
						let rowMetadata = fetched.1.map {
							ZagSourceRowMetadata(repository: $0)
						}
						return (fetched.0, fetched.1, rowMetadata)
					}
				}

				for await (url, repo, rowMetadata) in group {
					refreshingSourceURLs.remove(url.absoluteString)

					guard
						let repo,
						let source = batch.first(where: {
							$0.1.absoluteString == url.absoluteString
						})?.0,
						Storage.shared.getSources().contains(where: {
							$0.sourceURL?.absoluteString == url.absoluteString
						})
					else {
						continue
					}

					if let rowMetadata {
						rowMetadataByURL[url.absoluteString] = rowMetadata
					}
					refreshedSources[source] = repo
					self.sources = refreshedSources
				}
			}

			let savedSourceURLs = Set(
				Storage.shared.getSources().compactMap {
					$0.sourceURL?.absoluteString
				}
			)

			refreshedSources = refreshedSources.filter { source, _ in
				guard let url = source.sourceURL?.absoluteString else {
					return false
				}
				return savedSourceURLs.contains(url)
			}
		}

		ZagPerformanceMonitor.shared.record(
			.repositoriesFetch,
			since: metricStart,
			result: "completed"
		)
		print("[Zag Refresh Diagnostic] Repository fetch + publication — " + String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - diagnosticStart))
		let completedSources = refreshedSources
		let completedRepositories = Array(completedSources.values)
		let reconciliationStartedAt = CFAbsoluteTimeGetCurrent()

		// Match the background updater's complete-snapshot guarantee. A source
		// failure on cold launch must not turn a 15-update snapshot into six
		// simply because only some repositories finished loading.
		let configuredSourceURLs = Set(
			Storage.shared.getSources().compactMap { $0.sourceURL?.absoluteString }
		)
		let loadedSourceURLs = Set(
			completedSources.keys.compactMap { $0.sourceURL?.absoluteString }
		)
		let missingSourceURLs = configuredSourceURLs.subtracting(loadedSourceURLs)
		guard !Task.isCancelled else {
			print("[Zag Store Updates] Foreground refresh cancelled; retaining last update snapshot")
			ZagLogger.shared.warning("Updates", "Foreground refresh cancelled; retaining last update snapshot")
			return
		}

		// Keep successful Sources rows live even if a repository is temporarily
		// unavailable; however, do not treat a partial catalogue as a complete
		// basis for globally replacing the update count.
		self.sources = completedSources
		guard missingSourceURLs.isEmpty else {
			let message = "Incomplete foreground repository snapshot " +
				"(\(loadedSourceURLs.count)/\(configuredSourceURLs.count)); " +
				"missing: " + missingSourceURLs.sorted().joined(separator: ", ") +
				" — retaining last update snapshot"
			print("[Zag Store Updates] " + message)
			ZagLogger.shared.warning("Updates", message)
			return
		}

		if diagnosticSkipReconciliation {
			print("[Zag Refresh Diagnostic] Skipped origin + inventory/update reconciliation; total — " + String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - diagnosticStart))
			return
		}

		let originsStartedAt = CFAbsoluteTimeGetCurrent()
		let originsMetricStartedAt = ZagPerformanceMonitor.now()
		reconcileRepositoryOrigins()
		ZagPerformanceMonitor.shared.record(.repositoryOrigins, since: originsMetricStartedAt)
		let originsElapsed = CFAbsoluteTimeGetCurrent() - originsStartedAt
		print(
			"[Zag Store Sources] Origin reconciliation — " +
			String(format: "%.3fs", originsElapsed)
		)

		let updatesStartedAt = CFAbsoluteTimeGetCurrent()
		let inventoryMetricStartedAt = ZagPerformanceMonitor.now()
		await _refreshUpdatesUsingInstalledInventory(
			repositories: completedRepositories
		)
		ZagPerformanceMonitor.shared.record(.repositoryInventory, since: inventoryMetricStartedAt)
		let updatesElapsed = CFAbsoluteTimeGetCurrent() - updatesStartedAt
		let finalizationElapsed = CFAbsoluteTimeGetCurrent() - reconciliationStartedAt
		print(
			"[Zag Store Sources] Inventory + update reconciliation — " +
			String(format: "%.3fs", updatesElapsed)
		)
		print(
			"[Zag Store Sources] Refresh finalization — " +
			String(format: "%.3fs", finalizationElapsed)
		)
	}



	@MainActor
	private func _refreshUpdatesUsingInstalledInventory(
		repositories: [ASRepository]
	) async {
		let pairingCore = ZagRPPairingCore.shared

		// A paired device's Signed archive is not authoritative installed
		// state. During launch, reconciling against it can briefly replace
		// the persisted update count (e.g. 10) with a false lower count (4).
		// Keep the previous snapshot until the native inventory is loaded.
		// The successful inventory callback below publishes the final result.
		// Without pairing, Signed fallback remains the available source.
		let hasAuthoritativeInventory: Bool = {
			if case .loaded = pairingCore.installedAppsState { return true }
			return false
		}()
		if hasAuthoritativeInventory || !pairingCore.pairingFileExists {
			UpdateManager.shared.refresh(repositories: repositories)
		} else {
			ZagLogger.shared.info(
				"Updates",
				"Waiting for device inventory; preserving previous update snapshot"
			)
		}

		if case .refreshing = pairingCore.installedAppsState {
			// The active request will be observed through the shared inventory
			// state and the callback of its original caller. Do not start another.
			ZagLogger.shared.info(
				"Updates", "Inventory already refreshing; keeping immediately reconciled update snapshot"
			)
			return
		}

		guard pairingCore.pairingFileExists else {
			ZagLogger.shared.warning(
				"Updates", "No pairing file available; updates reconciled using Signed fallback"
			)
			return
		}

		do {
			try pairingCore.refreshInstalledApps { result in
				// The native callback is delivered on the main queue. Defer
				// reconciliation so the completed repository publication and
				// its isRefreshing/defer cleanup cannot race a fast callback.
				DispatchQueue.main.async {
					switch result {
					case .failure(let error):
						ZagLogger.shared.warning(
							"Updates",
							"Device inventory unavailable: \(error.localizedDescription); Signed fallback preserved"
						)
						return
					case .success:
						break
					}

					let configuredURLs = Set(
						Storage.shared.getSources().compactMap { $0.sourceURL?.absoluteString }
					)
					let currentlyLoaded = self.sources.filter { source, _ in
						guard let url = source.sourceURL?.absoluteString else { return false }
						return configuredURLs.contains(url)
					}
					let loadedURLs = Set(
						currentlyLoaded.keys.compactMap { $0.sourceURL?.absoluteString }
					)
					// Never replace a complete update snapshot with a partial
					// catalogue merely because the inventory arrived late.
					guard configuredURLs == loadedURLs,
						!self.isRefreshing,
						!UpdateManager.shared.isRepositoryRefreshInProgress
					else { return }
					UpdateManager.shared.refresh(
						repositories: Array(currentlyLoaded.values)
					)
				}
			}
		} catch {
			ZagLogger.shared.warning(
				"Updates",
				"Inventory request did not start: \(error.localizedDescription); initial update snapshot preserved"
			)
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

		// Provenance is only useful for apps Zag Store actually tracks. Older
		// builds populated these dictionaries for essentially the whole catalog,
		// which made every refresh build and persist tens of thousands of entries.
		var trackedBundleIDs = Set(
			(defaults.dictionary(forKey: "zagStore.repositoryAppOrigins") as? [String: String] ?? [:]).keys
		)
		trackedBundleIDs.formUnion(
			(defaults.dictionary(forKey: "zagStore.repositoryVariantOrigins") as? [String: String] ?? [:]).keys
		)
		trackedBundleIDs.formUnion(ZagRPPairingCore.shared.installedApps.keys)

		if let managedData = defaults.data(forKey: "zagStore.managedInstalledBundleIDs"),
		   let managed = try? JSONDecoder().decode(Set<String>.self, from: managedData) {
			trackedBundleIDs.formUnion(managed)
		}

		let signedRequest = Signed.fetchRequest()
		if let signedApps = try? Storage.shared.context.fetch(signedRequest) {
			trackedBundleIDs.formUnion(
				signedApps.compactMap { $0.identifier }.filter { !$0.isEmpty }
			)
		}

		// One-time cleanup of the old catalog-wide cache. Exact lineage written
		// after installs remains intact because all tracked IDs are preserved.
		let prunedOrigins = origins.filter { trackedBundleIDs.contains($0.key) }
		let prunedIcons = icons.filter { trackedBundleIDs.contains($0.key) }
		var changedOrigins = prunedOrigins.count != origins.count
		var changedIcons = prunedIcons.count != icons.count
		origins = prunedOrigins
		icons = prunedIcons

		// Preserve the actual candidate entry: several repositories contain
		// many releases of one bundle ID. Counting entries is not equivalent
		// to counting repository origins.
		var repositoriesByBundleID: [String: [(AltSource, ASRepository, ASRepository.App)]] = [:]
		if !trackedBundleIDs.isEmpty {
			for (storedSource, repository) in sources {
				for app in repository.apps {
					guard
						let bundleID = app.id,
						trackedBundleIDs.contains(bundleID)
					else {
						continue
					}
					repositoriesByBundleID[bundleID, default: []].append(
						(storedSource, repository, app)
					)
				}
			}
		}

		let recordedAppNames = defaults.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		let recordedVariantFingerprints = defaults.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]

		for (bundleID, matches) in repositoriesByBundleID {
			if origins[bundleID] == nil {
				let bySource = Dictionary(grouping: matches) { entry in
					entry.0.sourceURL?.absoluteString ??
					entry.1.id ??
					entry.1.website?.absoluteString ??
					entry.1.name ?? ""
				}.filter { !$0.key.isEmpty }

				let eligibleKeys: [String] = {
					let trackedName = recordedAppNames[bundleID]
					let trackedFingerprint = recordedVariantFingerprints[bundleID]
					guard let trackedFingerprint else {
						// A single source containing many *versions* is still just
						// one source, but do not infer across competing app names.
						guard bySource.count == 1,
							let group = bySource.values.first
						else { return [] }
						let names = Set(group.map {
							ZagVariantLineageResolver.normalizedName($0.2.currentName)
						})
						let fingerprints = Set(group.map {
							UpdateManager.variantIdentity(for: $0.2)
						})
						// Without a tracked variant, different descriptions may
						// represent different tweaks under the same name. Inferring
						// source ownership must not imply variant equivalence.
						return names.count == 1 && fingerprints.count == 1
							? Array(bySource.keys) : []
					}
					guard let trackedName, !trackedName.isEmpty else { return [] }
					let normalized = ZagVariantLineageResolver.normalizedName(trackedName)
					return bySource.compactMap { key, group -> String? in
						let matched = group.contains { entry in
							let app = entry.2
							guard ZagVariantLineageResolver.normalizedName(app.currentName) == normalized
							else { return false }
							// Only exact legacy fingerprints may establish missing
							// provenance. A shared bundle ID or a fuzzy hint cannot.
							if UpdateManager.variantIdentity(for: app) == trackedFingerprint {
								return true
							}
							return (app.versions ?? []).contains { version in
								guard let description = version.localizedDescription else { return false }
								return UpdateManager.variantIdentity(
									appName: app.currentName, variantDescription: description
								) == trackedFingerprint
							}
						}
						return matched ? key : nil
					}
				}()
				if eligibleKeys.count == 1,
					let selectedKey = eligibleKeys.first {
					origins[bundleID] = selectedKey
					changedOrigins = true
					ZagLogger.shared.info(
						"Updates",
						"Recovered unambiguous repository provenance for \(bundleID)"
					)
				}
			}

			guard let origin = origins[bundleID] else { continue }
			if let match = matches.first(where: { entry in
				let storedSource = entry.0
				let repository = entry.1
				return storedSource.sourceURL?.absoluteString == origin ||
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
		let sourceURL = source.sourceURL
		let removedURL = sourceURL?.absoluteString

		if let sourceURL {
			_dataService.removeCachedRepository(for: sourceURL)
			rowMetadataByURL.removeValue(forKey: sourceURL.absoluteString)
		}

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

	private static let persistedUpdateCountKey =
		"ZagStore.persistedUpdateCount"
	static let updateNotificationsEnabledKey =
		"ZagStore.updateNotificationsEnabled"
	private static let notifiedUpdateSignaturesKey =
		"ZagStore.notifiedUpdateSignatures"

	// The popup and every badge must count the same release-aware update set.
	var visibleUpdates: [AvailableUpdate] {
		let cutoff = Calendar.current.date(
			byAdding: .day, value: -30, to: Date()
		) ?? .distantPast
		let recent = ZagUpdateRowSnapshot.load(ZagUpdateRowSnapshot.recentKey)
			.filter { ($0.completedAt ?? .distantPast) >= cutoff }
		return updates.filter { update in
			let bundleID = update.app.id ?? update.id
			return !recent.contains { row in
				row.id == update.id && row.bundleID == bundleID &&
				ZagVariantLineageResolver.matchesCompletedRelease(
					availableVersion: update.availableVersion,
					availableBuild: update.availableBuild,
					completedVersion: row.version,
					completedBuild: row.build
				)
			}
		}
	}

	var updateCount: Int {
		// A successfully reconciled empty snapshot means zero, not stale history.
		if hasCompletedReconciliation { return visibleUpdates.count }
		return updates.isEmpty ? persistedUpdateCount : visibleUpdates.count
	}

	private var hasCompletedReconciliation = false
	var hasCompletedUpdateCheck: Bool { hasCompletedReconciliation }

	func updateCompletionDidChange() {
		objectWillChange.send()
		persistedUpdateCount = visibleUpdates.count
		UserDefaults.standard.set(persistedUpdateCount, forKey: Self.persistedUpdateCountKey)
		Task { await syncAppIconBadge() }
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
		let reconciliationStartedAt = ZagPerformanceMonitor.now()
		defer {
			ZagPerformanceMonitor.shared.record(
				.updateReconciliation,
				since: reconciliationStartedAt
			)
		}
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
		let persistedRepositoryOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryOrigins"
		) as? [String: String] ?? [:]
		let pairingCore = ZagRPPairingCore.shared
		let deviceInventory = pairingCore.installedApps
		let inventoryStatus: String = {
			switch pairingCore.installedAppsState {
			case .idle: return "idle"
			case .refreshing: return "refreshing"
			case .loaded(let count): return "loaded (reported \(count))"
			case .failed(let detail): return "failed: \(detail)"
			}
		}()

		// Only installed/signed bundle IDs are ever consulted below.
		// Indexing every app in enormous repositories allocates thousands
		// of unnecessary dictionary entries on the UI thread at refresh end.
		// Include both sources to keep device and Signed fallback semantics,
		// including diagnostics, exactly as before.
		let relevantIdentifiers = Set(deviceInventory.keys).union(
			signedApps.compactMap { $0.identifier }
		)
		let signedAppsByIdentifier = Dictionary(grouping: signedApps) {
			$0.identifier ?? ""
		}
		var repositoryAppsByIdentifier: [String: [(ASRepository, ASRepository.App)]] = [:]
		for repository in repositories {
			for candidate in repository.apps {
				guard let identifier = candidate.id,
				      relevantIdentifiers.contains(identifier) else { continue }
				repositoryAppsByIdentifier[identifier, default: []].append((repository, candidate))
			}
		}

		if case .loaded = pairingCore.installedAppsState {
			// Device inventory is authoritative for both installed state and
			// the version/build actually present on the iPhone. A Signed record
			// may represent a different IPA version and must not override it.
			for installed in deviceInventory.values {
				guard !installed.version.isEmpty else { continue }

				let bundleSignedApps = signedAppsByIdentifier[installed.bundleID] ?? []
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

				let repositoryMatches = repositoryAppsByIdentifier[installed.bundleID] ?? []
				guard !repositoryMatches.isEmpty else { continue }

				// RPPairing inventory is authoritative for installed state. An app does
				// not need to have been installed by Zag Store to be update-eligible.
				let repositoryNames = Set(
					repositoryMatches.map { $0.1.currentName }.filter { !$0.isEmpty }
				)
				let repositoryName = repositoryNames.count == 1
					? repositoryNames.first
					: nil

				let installedName =
					persistedAppOrigins[installed.bundleID] ??
					signedName ??
					repositoryName ??
					installed.bundleID

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
			// A prepared Signed record is not an installed app. When native
			// inventory is unavailable, preserve the pre-install version for
			// an in-flight or failed update, including after a cold restart.
			var overriddenBundleIDs = Set<String>()
			for app in signedApps {
				if let bundleID = app.identifier,
					let baseline = ZagUpdateTransactionManager.shared.pendingInstallationBaseline(
						bundleID: bundleID
					) {
					if overriddenBundleIDs.insert(bundleID).inserted {
						_addLocalApp(
							name: baseline.appName,
							identifier: bundleID,
							version: baseline.installedVersion,
							build: baseline.installedBuild,
							to: &localApps
						)
					}
					continue
				}
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
					"using Signed fallback: \(localApps.count) app(s), " +
					"\(overriddenBundleIDs.count) pending-install baseline(s)"
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

		// Defer selection until every compatible repository release has been
		// examined. The first entry in a repository is not necessarily newest.
		var selectedUpdates: [String: AvailableUpdate] = [:]
		var selectedLineageReasons: [String: String] = [:]
		var recoveredVariantLineages: [String: String] = [:]
		var rejectedNewerCandidates: [String: Set<String>] = [:]
		// Group only the installed identifiers. Avoid repeatedly walking the
		// entire Alan's Gigantic Repo while resolving release-note changes.
		var lineagePeersByKey: [String: [ASRepository.App]] = [:]

		let recordedOrigins = persistedRepositoryOrigins
		let recordedAppOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		let recordedVariantOrigins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]

		let localAppsByIdentifier = Dictionary(grouping: localApps) { $0.identifier }
		var repositoryAppNamesByIdentifier: [String: Set<String>] = [:]
		for identifier in localAppsByIdentifier.keys {
			for (_, candidate) in repositoryAppsByIdentifier[identifier] ?? [] {
				repositoryAppNamesByIdentifier[identifier, default: []].insert(
					_normalizedAppName(candidate.currentName)
				)
			}
		}

		// Only installed/local bundle IDs can produce updates. Iterate their
		// indexed repository candidates instead of walking the entire catalog.
		for identifier in localAppsByIdentifier.keys {
			for (repository, app) in repositoryAppsByIdentifier[identifier] ?? [] {
				guard
					let availableVersion = app.currentVersion,
					!availableVersion.isEmpty,
					app.currentDownloadUrl != nil
				else {
					continue
				}

				// Mirror the repository Update pill: installed bundle identity comes
				// from RPPairing. Explicit app/variant lineage below disambiguates
				// variants when Zag Store has previously recorded it.
				guard let candidates = localAppsByIdentifier[identifier],
					!candidates.isEmpty else {
					continue
				}

				let availableBuild = app.currentAppVersion?.build
				guard candidates.contains(where: {
					_isRepositoryReleaseNewer(
						availableVersion: availableVersion,
						availableBuild: availableBuild,
						installedVersion: $0.version,
						installedBuild: $0.build
					)
				}) else { continue }

				let recordedAppOrigin = recordedAppOrigins[identifier]
				let repositoryNames = repositoryAppNamesByIdentifier[identifier] ?? []
				let localNames = Set(candidates.map { _normalizedAppName($0.name) })
				let legacyMatchedNames = repositoryNames.intersection(localNames)
				let effectiveAppOrigin: String? = {
					if let recordedAppOrigin, !recordedAppOrigin.isEmpty {
						return recordedAppOrigin
					}
					if legacyMatchedNames.count == 1,
					   let normalizedMatch = legacyMatchedNames.first {
						let matchingRepositoryApps = (repositoryAppsByIdentifier[identifier] ?? []).filter {
							_normalizedAppName($0.1.currentName) == normalizedMatch
						}
						let variantIdentities = Set(matchingRepositoryApps.map {
							Self.variantIdentity(for: $0.1)
						})
						if variantIdentities.count == 1,
						   let candidate = matchingRepositoryApps.first {
							return candidate.1.currentName
						}
					}
					if repositoryNames.count == 1,
					   let candidate = (repositoryAppsByIdentifier[identifier] ?? []).first {
						return candidate.1.currentName
					}
					return nil
				}()

				if let effectiveAppOrigin,
				   _normalizedAppName(effectiveAppOrigin) != _normalizedAppName(app.currentName) {
					rejectedNewerCandidates[identifier, default: []].insert(
						"\(app.currentName) \(availableVersion) [different app name]"
					)
					continue
				}

				// Without a recorded variant fingerprint, a matching bundle ID
				// and display name cannot prove two modified IPAs are equivalent.
				// Keep the recorded repository boundary until explicit package
				// provenance verification is implemented. This prevents an Eevee
				// installation from silently becoming a Chroma Spotify update.
				if recordedVariantOrigins[identifier] == nil,
					let origin = recordedOrigins[identifier],
					!origin.isEmpty {
					var sourceAliases = Set([
						repository.id,
						repository.website?.absoluteString,
						repository.name
					].compactMap { $0 }.filter { !$0.isEmpty })
					if !sourceAliases.contains(origin) {
						for (storedSource, loaded) in SourcesViewModel.shared.sources {
							guard loaded.id == repository.id,
								loaded.website == repository.website,
								loaded.name == repository.name
							else { continue }
							if let url = storedSource.sourceURL?.absoluteString {
								sourceAliases.insert(url)
							}
						}
						if !sourceAliases.contains(origin) {
							rejectedNewerCandidates[identifier, default: []].insert(
								"\(app.currentName) \(availableVersion) [unverified cross-source variant]"
							)
							continue
						}
					}
				}

				var lineageRecovery: ZagVariantLineageResolver.Decision?
				if let recordedVariantOrigin = recordedVariantOrigins[identifier] {
					let decision: ZagVariantLineageResolver.Decision
					if recordedVariantOrigin == Self.variantIdentity(for: app) {
						// Exact matches are quick, but must still respect recorded
						// repository provenance; otherwise a sibling source can
						// win before the legitimate source is considered.
						decision = Self.variantLineageDecision(
							for: app,
							in: repository,
							trackedVariant: recordedVariantOrigin,
							trackedAppName: recordedAppOrigin,
							trackedRepository: recordedOrigins[identifier],
							sameNameCandidates: []
						)
					} else {
						let normalizedName = _normalizedAppName(app.currentName)
						let peerKey = [
							identifier,
							repository.id ?? "",
							repository.website?.absoluteString ?? "",
							repository.name ?? "",
							normalizedName
						].joined(separator: "|")
						if lineagePeersByKey[peerKey] == nil {
							lineagePeersByKey[peerKey] = (repositoryAppsByIdentifier[identifier] ?? [])
								.compactMap { source, candidate in
									guard source.id == repository.id,
										source.website == repository.website,
										source.name == repository.name,
										_normalizedAppName(candidate.currentName) == normalizedName
									else { return nil }
									return candidate
								}
						}
						decision = Self.variantLineageDecision(
							for: app,
							in: repository,
							trackedVariant: recordedVariantOrigin,
							trackedAppName: recordedAppOrigin,
							trackedRepository: recordedOrigins[identifier],
							sameNameCandidates: lineagePeersByKey[peerKey]
						)
					}
					guard decision.isMatch else {
						rejectedNewerCandidates[identifier, default: []].insert(
							"\(app.currentName) \(availableVersion) [\(decision.rawValue)]"
						)
						continue
					}
					if decision != .exactLegacyIdentity {
						lineageRecovery = decision
					}
				}

				for localApp in candidates {
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

					let suggestedUpdate = AvailableUpdate(
						app: app,
						source: repository,
						installedVersion: localApp.version,
						availableVersion: availableVersion,
						installedBuild: localApp.build,
						availableBuild: availableBuild
					)
					if let existing = selectedUpdates[localKey] {
						let comparison = ZagVariantLineageResolver.compareRelease(
							version: availableVersion, build: availableBuild,
							to: existing.availableVersion, build: existing.availableBuild
						)
						if comparison != .orderedDescending {
							// Prefer the first compatible release on an exact tie:
							// it has no meaningful version/build advantage.
							continue
						}
					}
					selectedUpdates[localKey] = suggestedUpdate
					if let lineageRecovery {
						selectedLineageReasons[localKey] = lineageRecovery.rawValue
					} else {
						selectedLineageReasons.removeValue(forKey: localKey)
					}
					break
				}
			}
		}

		let foundUpdates = Array(selectedUpdates.values)
		for (localKey, reason) in selectedLineageReasons {
			if let identifier = selectedUpdates[localKey]?.app.id {
				recoveredVariantLineages[identifier] = reason
			}
		}
		var diagnosticLines: [String] = []
		diagnosticLines.append("=== Zag Store Update Diagnostics ===")
		diagnosticLines.append("Tracked Variant Lineage:")
		let trackedLineageIDs = Set(recordedOrigins.keys)
			.union(recordedAppOrigins.keys)
			.union(recordedVariantOrigins.keys)
		if trackedLineageIDs.isEmpty {
			diagnosticLines.append("- <none>")
		} else {
			for identifier in trackedLineageIDs.sorted() {
				diagnosticLines.append(
					"- id=\(identifier) | appOrigin=\(recordedAppOrigins[identifier] ?? "<none>") | " +
					"variantOrigin=\(recordedVariantOrigins[identifier] ?? "<none>") | " +
					"repositoryOrigin=\(recordedOrigins[identifier] ?? "<none>")"
				)
			}
		}
		diagnosticLines.append("")
		diagnosticLines.append(
			"Inventory status: \(inventoryStatus) | pairingFilePresent=\(pairingCore.pairingFileExists) | " +
			"entries=\(deviceInventory.count) | localState=\(localApps.count) | " +
			"source=\(inventoryStatus.hasPrefix("loaded") ? "RPPairing" : "Signed fallback")"
		)
		diagnosticLines.append("Raw device inventory:")
		for installed in deviceInventory.values.sorted(by: { $0.bundleID < $1.bundleID }) {
			let origin = recordedOrigins[installed.bundleID] ?? "<none>"
			let appOrigin = recordedAppOrigins[installed.bundleID] ?? "<none>"
			diagnosticLines.append("- id=\(installed.bundleID) | version=\(installed.version) | build=\(installed.build.isEmpty ? "<none>" : installed.build) | origin=\(origin) | appOrigin=\(appOrigin)")
			let matchingSigned = signedAppsByIdentifier[installed.bundleID] ?? []
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

			let repoIdentities = Set(
				(repositoryAppsByIdentifier[installed.bundleID] ?? []).map { repository, candidate in
					"\(candidate.currentName) | repo=\(repository.name ?? "<unknown>")"
				}
			)
			for identity in repoIdentities.sorted() {
				diagnosticLines.append("  repo: \(identity)")
			}

			let exactReleaseMatches = (repositoryAppsByIdentifier[installed.bundleID] ?? []).compactMap {
				repository, candidate -> String? in
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
		diagnosticLines.append("")
		diagnosticLines.append("Recovered release-note lineages:")
		if recoveredVariantLineages.isEmpty {
			diagnosticLines.append("- <none>")
		} else {
			for identifier in recoveredVariantLineages.keys.sorted() {
				diagnosticLines.append("- \(identifier) | \(recoveredVariantLineages[identifier] ?? "")")
			}
		}
		diagnosticLines.append("")
		diagnosticLines.append("Rejected newer repository candidates:")
		if rejectedNewerCandidates.isEmpty {
			diagnosticLines.append("- <none>")
		} else {
			for identifier in rejectedNewerCandidates.keys.sorted() {
				for reason in (rejectedNewerCandidates[identifier] ?? []).sorted().prefix(8) {
					diagnosticLines.append("- \(identifier) | \(reason)")
				}
			}
		}
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

		// Distinguish repository matching from the separate release-aware
		// Updated Recently suppression. This diagnostic never changes eligibility.
		let visibleCount = visibleUpdates.count
		let suppressedRecentCount = updates.count - visibleCount
		diagnosticLines.append("")
		diagnosticLines.append("Suppressed by Updated Recently:")
		let visibleIDs = Set(visibleUpdates.map {
			($0.app.id ?? "") + "|" + $0.availableVersion
		})
		let suppressedUpdates = updates.filter {
			!visibleIDs.contains(($0.app.id ?? "") + "|" + $0.availableVersion)
		}
		if suppressedUpdates.isEmpty {
			diagnosticLines.append("- <none>")
		} else {
			for update in suppressedUpdates {
				diagnosticLines.append(
					"- \(update.app.currentName) | \(update.availableVersion) | \(update.source.name ?? "Unknown")"
				)
			}
		}
		diagnosticLines.append("")
		diagnosticLines.append(
			"Reconciliation: repository candidates for \(repositoryAppsByIdentifier.count) IDs; " +
			"installed inventory \(deviceInventory.count); " +
			"matched \(updates.count); visible \(visibleCount); " +
			"suppressed by Updated Recently \(suppressedRecentCount)"
		)
		let acceptedIDs = Set(updates.compactMap { $0.app.id })
		diagnosticLines.append("")
		diagnosticLines.append("Local apps without accepted updates:")
		for localApp in localApps.sorted(by: { $0.name < $1.name }) {
			guard !acceptedIDs.contains(localApp.identifier) else { continue }
			let repoCandidates = repositoryAppsByIdentifier[localApp.identifier] ?? []
			let hasNewerCandidate = repoCandidates.contains { entry in
				let candidate = entry.1
				guard let version = candidate.currentVersion, !version.isEmpty else { return false }
				return _isRepositoryReleaseNewer(
					availableVersion: version,
					availableBuild: candidate.currentAppVersion?.build,
					installedVersion: localApp.version,
					installedBuild: localApp.build
				)
			}
			let explanation = repoCandidates.isEmpty
				? "not found in loaded repositories"
				: (hasNewerCandidate
					? "newer candidate exists; examine app/variant lineage"
					: "no strictly newer version in loaded repositories")
			diagnosticLines.append("- \(localApp.name) | id=\(localApp.identifier) | \(explanation)")
		}
		diagnosticsReport = diagnosticLines.joined(separator: "\n")

		hasCompletedReconciliation = true
		persistedUpdateCount = visibleCount
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


	/// Legacy variant identities include release notes, which are not stable
	/// across updates. Recover a successor only when its recorded source and
	/// app name agree and that source has an unambiguous matching entry (or a
	/// unique historical release fingerprint).
	static func variantLineageDecision(
		for app: ASRepository.App,
		in source: ASRepository?,
		trackedVariant: String,
		trackedAppName: String?,
		trackedRepository: String?,
		sameNameCandidates: [ASRepository.App]? = nil
	) -> ZagVariantLineageResolver.Decision {
		let currentIdentity = variantIdentity(for: app)

		guard let source else { return .unknownSource }
		let normalizedName = ZagVariantLineageResolver.normalizedName(app.currentName)
		guard let trackedAppName,
			ZagVariantLineageResolver.normalizedName(trackedAppName) == normalizedName
		else { return .differentAppName }

		var aliases = Set([
			source.id,
			source.website?.absoluteString,
			source.name
		].compactMap { $0 }.filter { !$0.isEmpty })
		if let trackedRepository, !aliases.contains(trackedRepository) {
			for (storedSource, loaded) in SourcesViewModel.shared.sources {
				guard loaded.id == source.id,
					loaded.website == source.website,
					loaded.name == source.name
				else { continue }
				if let url = storedSource.sourceURL?.absoluteString {
					aliases.insert(url)
				}
			}
		}

		if trackedVariant == currentIdentity {
			if let trackedRepository, !trackedRepository.isEmpty,
				!aliases.contains(trackedRepository) { return .differentSource }
			return .exactLegacyIdentity
		}

		let peers = sameNameCandidates ?? source.apps.filter {
			$0.id == app.id &&
				ZagVariantLineageResolver.normalizedName($0.currentName) == normalizedName
		}
		func containsLegacyHistory(_ candidate: ASRepository.App) -> Bool {
			var descriptions = candidate.versions?.compactMap { $0.localizedDescription } ?? []
			if let legacy = candidate.versionDescription { descriptions.append(legacy) }
			if let description = candidate.currentDescription { descriptions.append(description) }
			return descriptions.contains {
				variantIdentity(appName: candidate.currentName, variantDescription: $0) == trackedVariant
			}
		}
		let hasHistory = peers.count > 1 && containsLegacyHistory(app)
		let historyCount = hasHistory
			? peers.filter { containsLegacyHistory($0) }.count
			: 0

		// Same-name entries frequently represent different releases rather than
		// different variants. A distinctive old mod/publisher marker can prove
		// continuity across versions, even when the full notes have changed.
		let stableMarker = ZagVariantLineageResolver.hasStableVariantMarker(
			trackedVariant: trackedVariant,
			candidateVariant: currentIdentity
		)
		let sameReleaseMatches = stableMarker ? peers.filter { peer in
			guard peer.currentVersion == app.currentVersion,
				ZagVariantLineageResolver.hasStableVariantMarker(
					trackedVariant: trackedVariant,
					candidateVariant: variantIdentity(for: peer)
				)
			else { return false }
			return true
		} : []
		// Multiple packages for the same version with the same visible marker
		// are not evidence that those IPA binaries are interchangeable.
		let packageURLs = Set(sameReleaseMatches.compactMap {
			$0.currentDownloadUrl?.absoluteString
		})
		let hasAmbiguousSameRelease = packageURLs.count > 1
		let stableEvidence = stableMarker && !hasAmbiguousSameRelease

		return ZagVariantLineageResolver.resolve(
			trackedVariant: trackedVariant,
			trackedAppName: trackedAppName,
			trackedRepository: trackedRepository,
			candidateAppName: app.currentName,
			candidateVariant: currentIdentity,
			candidateRepositoryAliases: aliases,
			sameSourceSameNameCount: peers.count,
			hasMatchingHistoricalRelease: hasHistory,
			historicalReleaseMatchCount: historyCount,
			hasStableVariantEvidence: stableEvidence
		)
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

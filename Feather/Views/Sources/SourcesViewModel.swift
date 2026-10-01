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
			// The repository snapshot is already complete. It is safe to
			// reconcile updates against it without entering a refresh cycle.
			UpdateManager.shared.refresh(
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
		UpdateManager.shared.refresh(
			repositories: completedRepositories
		)
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

		for app in signedApps {
			_addLocalApp(
				name: app.name,
				identifier: app.identifier,
				version: app.version,
				build: _buildVersion(for: app),
				to: &localApps
			)
		}

		// Zag Store: Imported packages are not installed-state evidence.
		// Signed records are authoritative for update detection.

		print(
			"[Zag Store Updates] Local identities: \(localApps.count)"
		)

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

				let candidates = localApps.filter {
					$0.identifier == identifier
				}

				guard !candidates.isEmpty else {
					continue
				}

				for localApp in candidates {
					guard _sameAppIdentity(
						installedName: localApp.name,
						repositoryName: app.currentName
					) else {
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

		updates = foundUpdates.sorted {
			$0.app.currentName.localizedCaseInsensitiveCompare(
				$1.app.currentName
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

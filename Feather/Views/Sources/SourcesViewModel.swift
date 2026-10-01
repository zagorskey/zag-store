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

		await MainActor.run {
			self.sources = self.sources.filter { source, _ in
				guard let sourceURL = source.sourceURL?.absoluteString else {
					return false
				}
				return currentSourceURLs.contains(sourceURL)
			}
		}

		if !refresh, sources.allSatisfy({
			self.sources[$0] != nil
		}) {
			// The repository snapshot is already complete. It is safe to
			// reconcile updates against it without entering a refresh cycle.
			await MainActor.run {
				UpdateManager.shared.refresh(
					repositories: Array(self.sources.values)
				)
			}
			return
		}

		isFinished = false

		await MainActor.run {
			self.isRefreshing = true
		}

		defer {
			isFinished = true

			Task { @MainActor in
				self.isRefreshing = false
			}
		}

		let sourcesArray = Array(sources)

		// Build the next repository state off-screen. In particular, do not
		// clear self.sources or UpdateManager while network requests are in
		// flight: the last completed update result remains authoritative until
		// the new refresh has fully finished.
		var refreshedSources: [AltSource: ASRepository] = refresh
			? [:]
			: await MainActor.run { self.sources }

		for startIndex in stride(
			from: 0,
			to: sourcesArray.count,
			by: batchSize
		) {
			let endIndex = min(
				startIndex + batchSize,
				sourcesArray.count
			)

			let batch = sourcesArray[startIndex..<endIndex]

			let batchResults = await withTaskGroup(
				of: (AltSource, ASRepository?).self,
				returning: [AltSource: ASRepository].self
			) { group in
				for source in batch {
					group.addTask {
						guard let url = source.sourceURL else {
							return (source, nil)
						}

						return await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) {
								(result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (source, repo))
								case .failure:
									continuation.resume(returning: (source, nil))
								}
							}
						}
					}
				}

				var results = [AltSource: ASRepository]()
				for await (source, repo) in group {
					if let repo {
						results[source] = repo
					}
				}
				return results
			}

			let savedSourceURLs = Set(
				Storage.shared.getSources().compactMap {
					$0.sourceURL?.absoluteString
				}
			)

			for (source, repo) in batchResults {
				guard
					let url = source.sourceURL?.absoluteString,
					savedSourceURLs.contains(url)
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

		await MainActor.run {
			// Publish the repository snapshot and its derived update state as
			// one completed refresh. Until this point the previous Updates
			// pill/count and app-icon badge remain untouched.
			self.sources = refreshedSources
			UpdateManager.shared.refresh(
				repositories: Array(refreshedSources.values)
			)
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

	struct AvailableUpdate: Identifiable {
		let app: ASRepository.App
		let source: ASRepository
		let installedVersion: String
		let availableVersion: String

		var id: String {
			app.id ?? app.currentUniqueId
		}
	}

	private struct LocalApp {
		let name: String
		let identifier: String
		let version: String
	}

	@Published private(set) var updates: [AvailableUpdate] = []

	var updateCount: Int {
		updates.count
	}

	private init() {}


	// MARK: - Zag Store App Icon Badge

	func requestBadgePermission() async {
		do {
			let granted = try await UNUserNotificationCenter.current()
				.requestAuthorization(options: [.badge])

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
								"repo=\(repository.name)"
						)
						continue
					}

					guard _compareVersions(
						availableVersion,
						localApp.version
					) == .orderedDescending else {
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
							availableVersion: availableVersion
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
					"repo=\(update.source.name)"
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
					version: version
				)
			}
		} else {
			apps.append(
				LocalApp(
					name: name,
					identifier: identifier,
					version: version
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

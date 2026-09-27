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

// MARK: - Class
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		
		// check if sources to be fetched are the same as before, if yes, return
		// also skip check if refresh is true
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		
		// isfinished is used to prevent multiple fetches at the same time
		isFinished = false
		defer { isFinished = true }
		
		await MainActor.run {
			self.sources = [:]
		}
		
		let sourcesArray = Array(sources)
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = sourcesArray[startIndex..<endIndex]
			
			let batchResults = await withTaskGroup(of: (AltSource, ASRepository?).self, returning: [AltSource: ASRepository].self) { group in
				for source in batch {
					group.addTask {
						guard let url = source.sourceURL else {
							return (source, nil)
						}
						
						return await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (source, repo))
								case .failure(_):
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
			
			await MainActor.run {
				for (source, repo) in batchResults {
					self.sources[source] = repo
				}
			}
		}
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

	@Published private(set) var updates: [AvailableUpdate] = []

	var updateCount: Int {
		updates.count
	}

	private init() {}

	func refresh(
		repositories: [ASRepository],
		signedApps: [Signed],
		importedApps: [Imported]
	) {
		var localVersions: [String: String] = [:]

		for app in signedApps {
			_addLocalVersion(
				identifier: app.identifier,
				version: app.version,
				to: &localVersions
			)
		}

		for app in importedApps {
			_addLocalVersion(
				identifier: app.identifier,
				version: app.version,
				to: &localVersions
			)
		}

		var foundUpdates: [AvailableUpdate] = []
		var seenIdentifiers = Set<String>()

		for repository in repositories {
			for app in repository.apps {
				guard
					let identifier = app.id,
					!identifier.isEmpty,
					let availableVersion = app.currentVersion,
					!availableVersion.isEmpty,
					let installedVersion = localVersions[identifier],
					_compareVersions(availableVersion, installedVersion) == .orderedDescending
				else {
					continue
				}

				guard seenIdentifiers.insert(identifier).inserted else {
					continue
				}

				foundUpdates.append(
					AvailableUpdate(
						app: app,
						source: repository,
						installedVersion: installedVersion,
						availableVersion: availableVersion
					)
				)
			}
		}

		updates = foundUpdates.sorted {
			$0.app.currentName.localizedCaseInsensitiveCompare(
				$1.app.currentName
			) == .orderedAscending
		}

		print("[Zag Store Updates] Check complete: \(updates.count) update(s)")

		for update in updates {
			print(
				"[Zag Store Updates] \(update.app.currentName): " +
				"\(update.installedVersion) -> \(update.availableVersion)"
			)
		}
	}

	func update(for identifier: String?) -> AvailableUpdate? {
		guard let identifier else {
			return nil
		}

		return updates.first {
			$0.app.id == identifier
		}
	}

	func hasUpdate(for identifier: String?) -> Bool {
		update(for: identifier) != nil
	}

	private func _addLocalVersion(
		identifier: String?,
		version: String?,
		to versions: inout [String: String]
	) {
		guard
			let identifier,
			!identifier.isEmpty,
			let version,
			!version.isEmpty
		else {
			return
		}

		if let existing = versions[identifier] {
			if _compareVersions(version, existing) == .orderedDescending {
				versions[identifier] = version
			}
		} else {
			versions[identifier] = version
		}
	}

	private func _compareVersions(
		_ lhs: String,
		_ rhs: String
	) -> ComparisonResult {
		lhs.compare(
			rhs,
			options: [.numeric, .caseInsensitive]
		)
	}
}

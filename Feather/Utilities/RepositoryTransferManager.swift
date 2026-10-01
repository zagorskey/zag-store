//
//  RepositoryTransferManager.swift
//  Zag Store
//

import Foundation
import AltSourceKit
import NimbleJSON
import OSLog
import UIKit

@MainActor
final class RepositoryTransferManager {
	static let shared = RepositoryTransferManager()

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	private struct ZagRepositoryBackup: Codable {
		let format: String
		let version: Int
		let repositories: [String]
	}

	private let dataService = NBFetchService()

	private init() {}


	// MARK: - Import

	func importRepositories(
		from text: String?,
		completion: @escaping (Int) -> Void
	) {
		guard let text, !text.isEmpty else {
			showError("No repository data found.")
			completion(0)
			return
		}

		let repoURLs = repositoryURLs(from: text)

		guard !repoURLs.isEmpty else {
			showError("No valid repositories found.")
			completion(0)
			return
		}

		importRepositoryURLs(
			repoURLs,
			completion: completion
		)
	}

	func importRepositories(
		fromFile url: URL,
		completion: @escaping (Int) -> Void
	) {
		let hasAccess =
			url.startAccessingSecurityScopedResource()

		defer {
			if hasAccess {
				url.stopAccessingSecurityScopedResource()
			}
		}

		do {
			let data = try Data(contentsOf: url)

			if let backup = try? JSONDecoder().decode(
				ZagRepositoryBackup.self,
				from: data
			) {
				let urls = backup.repositories.compactMap {
					URL(string: $0)
				}

				guard !urls.isEmpty else {
					showError(
						"The repository backup contains no valid repositories."
					)
					completion(0)
					return
				}

				importRepositoryURLs(
					urls,
					completion: completion
				)

				return
			}

			guard let text = String(
				data: data,
				encoding: .utf8
			) else {
				showError(
					"The selected file could not be read."
				)
				completion(0)
				return
			}

			importRepositories(
				from: text,
				completion: completion
			)
		} catch {
			showError(error.localizedDescription)
			completion(0)
		}
	}


	// MARK: - Export

	func makeExportFile() -> URL? {
		let sources = Storage.shared.getSources()

		let repositoryURLs = sources.compactMap {
			$0.sourceURL?.absoluteString
		}

		guard !repositoryURLs.isEmpty else {
			showError("No repositories to export.")
			return nil
		}

		let backup = ZagRepositoryBackup(
			format: "Zag Store Repositories",
			version: 1,
			repositories: repositoryURLs
		)

		do {
			let data = try JSONEncoder.pretty.encode(
				backup
			)

			let url = FileManager.default
				.temporaryDirectory
				.appendingPathComponent(
					"Zag-Store-Repositories.zagrepos"
				)

			try? FileManager.default.removeItem(
				at: url
			)

			try data.write(
				to: url,
				options: .atomic
			)

			return url
		} catch {
			showError(error.localizedDescription)
			return nil
		}
	}

	func copyRepositoriesToClipboard() {
		let sources = Storage.shared.getSources()

		let repositoryURLs = sources.compactMap {
			$0.sourceURL?.absoluteString
		}

		guard !repositoryURLs.isEmpty else {
			showError("No repositories to copy.")
			return
		}

		UIPasteboard.general.string =
			repositoryURLs.joined(separator: "\n")

		UIAlertController.showAlertWithOk(
			title: .localized("Success"),
			message: .localized(
				"Repositories copied to clipboard"
			)
		)
	}


	// MARK: - Decode

	private func repositoryURLs(
		from text: String
	) -> [URL] {
		if let data = text.data(using: .utf8),
		   let backup = try? JSONDecoder().decode(
				ZagRepositoryBackup.self,
				from: data
		   ) {
			return backup.repositories.compactMap {
				URL(string: $0)
			}
		}

		let handler = ASDeobfuscator(with: text)

		return handler.decode().compactMap {
			URL(string: $0)
		}
	}


	// MARK: - Import Worker

	private func importRepositoryURLs(
		_ repoURLs: [URL],
		completion: @escaping (Int) -> Void
	) {
		Task {
			let fetched =
				await concurrentFetchRepositories(
					from: repoURLs
				)

			let repositories = Dictionary(
				fetched,
				uniquingKeysWith: {
					first, _ in first
				}
			)

			guard !repositories.isEmpty else {
				showError(
					"No repositories could be imported."
				)
				completion(0)
				return
			}

			Storage.shared.addSources(
				repos: repositories
			) { error in
				if let error {
					self.showError(
						error.localizedDescription
					)
					completion(0)
					return
				}

				UIAlertController.showAlertWithOk(
					title: .localized("Success"),
					message:
						"\(repositories.count) repositories imported"
				)

				completion(repositories.count)
			}
		}
	}


	// MARK: - Repository Fetching

	private func concurrentFetchRepositories(
		from urls: [URL]
	) async -> [(URL, ASRepository)] {
		await withTaskGroup(
			of: (URL, ASRepository)?.self
		) { group in
			for url in urls {
				group.addTask { [dataService] in
					await withCheckedContinuation {
						continuation in

						dataService.fetch(
							from: url
						) {
							(result: RepositoryDataHandler) in

							switch result {
							case .success(
								let repository
							):
								continuation.resume(
									returning: (
										url,
										repository
									)
								)

							case .failure(
								let error
							):
								Logger.misc.error(
									"Failed to fetch \(url): \(error.localizedDescription)"
								)

								continuation.resume(
									returning: nil
								)
							}
						}
					}
				}
			}

			var results:
				[(URL, ASRepository)] = []

			for await result in group {
				if let result {
					results.append(result)
				}
			}

			return results
		}
	}


	// MARK: - Alerts

	private func showError(
		_ message: String
	) {
		UIAlertController.showAlertWithOk(
			title: .localized("Error"),
			message: message
		)
	}
}


// MARK: - JSON Formatting

private extension JSONEncoder {
	static var pretty: JSONEncoder {
		let encoder = JSONEncoder()

		encoder.outputFormatting = [
			.prettyPrinted,
			.sortedKeys,
			.withoutEscapingSlashes
		]

		return encoder
	}
}

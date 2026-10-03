//
//  SourcesAddView.swift
//  Zag Store
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import AltSourceKit
import NimbleJSON
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - View

struct SourcesAddView: View {
	typealias RepositoryDataHandler =
		Result<ASRepository, Error>

	@Environment(\.dismiss)
	var dismiss

	private let _dataService = NBFetchService()

	@State
	private var _filteredRecommendedSourcesData:
		[(url: URL, data: ASRepository)] = []

	@State
	var recommendedSourcesData:
		[(url: URL, data: ASRepository)] = []

	@State
	private var _sourceURL = ""

	let recommendedSources: [URL] = [
		"https://raw.githubusercontent.com/claration/Feather/refs/heads/main/app-repo.json",
		"https://raw.githubusercontent.com/Aidoku/Aidoku/altstore/apps.json",
		"https://github.com/chachillie/Flycast-iOS/raw/main/flycast-ios.json",
		"https://xitrix.github.io/iTorrent/AltStore.json",
		"https://altstore.oatmealdome.me/",
		"https://raw.githubusercontent.com/LiveContainer/LiveContainer/refs/heads/main/apps.json",
		"https://pokemmo.com/altstore",
		"https://provenance-emu.com/apps.json",
		"https://community-apps.sidestore.io/sidecommunity.json",
		"https://alt.getutm.app",
		"https://raw.githubusercontent.com/paigely/Navic/refs/heads/master/app-repo.json",
		"https://stikdebug.xyz/index.json",
		"https://apps.manicemu.site/altstore",
		"https://alt.crystall1ne.dev"
	].compactMap {
		URL(string: $0)
	}


	// MARK: - Body

	var body: some View {
		NBNavigationView(
			.localized("Add Source"),
			displayMode: .inline
		) {
			Form {
				NBSection(
					.localized("Source URL")
				) {
					TextField(
						.localized(
							"Enter Source URL"
						),
						text: $_sourceURL
					)
					.keyboardType(.URL)
					.textInputAutocapitalization(
						.never
					)
					.toolbar {
						ToolbarItemGroup(placement: .keyboard) {
							Button(".json") {
								_appendJSONSuffix()
							}
							.fontWeight(.semibold)

							Spacer()

							Button(.localized("Done")) {
								UIApplication.shared.sendAction(
									#selector(UIResponder.resignFirstResponder),
									to: nil,
									from: nil,
									for: nil
								)
							}
						}
					}
				} footer: {
					Text(
						.localized(
							"The only supported repositories are AltStore repositories."
						)
					)

					Text(
						verbatim:
							"[\(String.localized("Learn more about how to setup a repository..."))](https://faq.altstore.io/developers/make-a-source)"
					)
				}

				if !_filteredRecommendedSourcesData
					.isEmpty {

					NBSection(
						.localized("Featured")
					) {
						ForEach(
							_filteredRecommendedSourcesData,
							id: \.url
						) { url, source in
							HStack(
								spacing: 2
							) {
								FRIconCellView(
									title:
										source.name ??
										.localized(
											"Unknown"
										),
									subtitle:
										url.absoluteString,
									iconUrl:
										source.currentIconURL
								)

								Button {
									Storage.shared
										.addSource(
											url,
											repository:
												source
										) { _ in
											_refreshFilteredRecommendedSourcesData()
										}
								} label: {
									NBButton(
										.localized(
											"Add"
										),
										systemImage:
											"arrow.down",
										style:
											.text
									)
								}
							}
						}
					} footer: {
						Text(
							.localized(
								"Open an [issue](https://github.com/claration/Feather/issues) on GitHub if you want your source to be featured."
							)
						)
					}
				}
			}
			.toolbar {
				NBToolbarButton(
					role: .cancel
				)

				NBToolbarButton(
					.localized("Save"),
					style: .text,
					placement:
						.confirmationAction,
					isDisabled:
						_sourceURL.isEmpty
				) {
					FR.handleSource(
						_sourceURL
					) {
						dismiss()
					}
				}
			}
			.animation(
				.default,
				value:
					_filteredRecommendedSourcesData
						.map {
							$0.data.id ?? ""
						}
			)
			.task {
				await _fetchRecommendedRepositories()
			}
		}
	}


	// MARK: - Source URL Keyboard

	private func _appendJSONSuffix() {
		let trimmed = _sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			_sourceURL = ".json"
			return
		}

		guard !trimmed.lowercased().hasSuffix(".json") else {
			_sourceURL = trimmed
			return
		}

		_sourceURL = trimmed + ".json"
	}


	// MARK: - Recommended Sources

	private func _refreshFilteredRecommendedSourcesData() {
		let filtered =
			recommendedSourcesData
				.filter { url, data in
					let id =
						data.id ??
						url.absoluteString

					return !Storage.shared
						.sourceExists(id)
				}
				.sorted { lhs, rhs in
					let lhsName =
						lhs.data.name ?? ""

					let rhsName =
						rhs.data.name ?? ""

					return lhsName
						.localizedCaseInsensitiveCompare(
							rhsName
						) == .orderedAscending
				}

		_filteredRecommendedSourcesData =
			filtered
	}

	private func _fetchRecommendedRepositories() async {
		let fetched =
			await _concurrentFetchRepositories(
				from: recommendedSources
			)

		await MainActor.run {
			recommendedSourcesData =
				fetched

			_refreshFilteredRecommendedSourcesData()
		}
	}


	// MARK: - Repository Fetching

	private func _concurrentFetchRepositories(
		from urls: [URL]
	) async -> [
		(url: URL, data: ASRepository)
	] {
		var results:
			[(url: URL, data: ASRepository)] = []

		let dataService = _dataService

		await withTaskGroup(
			of: Void.self
		) { group in
			for url in urls {
				group.addTask {
					await withCheckedContinuation {
						continuation in

						dataService
							.fetch(
								from: url
							) {
								(result:
									RepositoryDataHandler)
								in

								switch result {
								case .success(
									let repo
								):
									Task {
										@MainActor in

										results
											.append(
												(
													url:
														url,
													data:
														repo
												)
											)
									}

								case .failure(
									let error
								):
									Logger.misc.error(
										"Failed to fetch \(url): \(error.localizedDescription)"
									)
								}

								continuation
									.resume()
							}
					}
				}
			}

			await group.waitForAll()
		}

		return results
	}
}

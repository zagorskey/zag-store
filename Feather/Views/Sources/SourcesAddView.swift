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
import NukeUI
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - View

struct SourcesAddView: View {
	typealias RepositoryDataHandler =
		Result<ASRepository, Error>

	@Environment(\.dismiss)
	var dismiss

	@Environment(\.colorScheme)
	private var colorScheme

	private let _dataService = NBFetchService()

	@State
	private var _filteredRecommendedSourcesData:
		[(url: URL, data: ASRepository)] = []

	@State
	var recommendedSourcesData:
		[(url: URL, data: ASRepository)] = []

	@State
	private var _sourceURL = ""

	static let zagFeaturedSourceURLs: [URL] = [
		"https://repository.apptesters.org",
		"https://altstore.fouadraheb.com",
		"https://ipa.cypwn.xyz/cypwn.json",
		"https://fastsign.dev/repo.json",
		"https://xitrix.github.io/iTorrent/AltStore.json",
		"https://github.com/jaydenjcpy/Eevee-Alt-Source/raw/refs/heads/main/apps.json",
		"https://raw.githubusercontent.com/mrdrvt99/Altstore-Repository/main/ytkace.json",
		"https://raw.githubusercontent.com/VortXTV/VortX/main/altstore/source.json",
		"https://dl.strem.io/apple/altstore/source.json",
		"https://alt.getutm.app",
		"https://github.com/chachillie/Flycast-iOS/raw/main/flycast-ios.json",
		"https://altstore.oatmealdome.me/"
	].compactMap { URL(string: $0) }

	let recommendedSources: [URL] = SourcesAddView.zagFeaturedSourceURLs

	private var popupBackground: Color {
		colorScheme == .dark ? Color(hex: "#1C1C1E") : Color(hex: "#F2F1F6")
	}

	private var sectionBackground: Color {
		colorScheme == .dark ? Color(hex: "#2C2C2E") : Color(hex: "#FFFFFF")
	}

	private var separatorColor: Color {
		colorScheme == .dark ? Color(hex: "#403F44") : Color(hex: "#E7E7E9")
	}

	private var pillBackground: Color {
		colorScheme == .dark ? Color(hex: "#3E3D42") : Color(hex: "#EEEEF0")
	}


	// MARK: - Body

	var body: some View {
		NBNavigationView(
			.localized("Add Source"),
			displayMode: .inline
		) {
			Form {
				Section {
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
						ToolbarItem(placement: .keyboard) {
							HStack(spacing: 4) {
								HStack(spacing: 0) {
									ForEach(0...9, id: \.self) { digit in
										Button(String(digit)) {
											_sourceURL.append(String(digit))
										}
										.font(.callout.monospacedDigit())
										.frame(maxWidth: .infinity)
									}
								}
								.frame(maxWidth: .infinity)

								Button(".json") {
									_appendJSONSuffix()
								}
								.fontWeight(.semibold)
								.fixedSize()

								Button(.localized("Done")) {
									UIApplication.shared.sendAction(
										#selector(UIResponder.resignFirstResponder),
										to: nil,
										from: nil,
										for: nil
									)
								}
								.fontWeight(.semibold)
								.fixedSize()
							}
							.frame(maxWidth: .infinity)
							.padding(.vertical, 6)
						}
					}
				} header: {
					Text(.localized("Source URL"))
						.font(.headline)
						.foregroundStyle(.secondary)
						.textCase(nil)
				} footer: {
					VStack(alignment: .leading, spacing: 4) {
						Text(.localized("The only supported repositories are AltStore repositories."))
						Text(
							verbatim:
								"[\(String.localized("Learn more about how to setup a repository..."))](https://faq.altstore.io/developers/make-a-source)"
						)
					}
					.font(.subheadline)
					.foregroundStyle(.secondary)
				}

				Section {
					if _filteredRecommendedSourcesData.isEmpty {
						HStack {
							Spacer()
							ProgressView()
							Spacer()
						}
						.frame(height: 62)
						.listRowSeparator(.hidden)
					} else {
						ForEach(
							_filteredRecommendedSourcesData,
							id: \.url
						) { url, source in
							HStack(spacing: 10) {
								LazyImage(url: source.currentIconURL) { state in
									if let image = state.image {
										image.appIconStyle(size: 62)
									} else {
										Image("App_Unknown")
											.appIconStyle(size: 62)
									}
								}

								VStack(alignment: .leading, spacing: 2) {
									Text(source.name ?? .localized("Unknown"))
										.zagContentTitleStyle()
										.lineLimit(1)

									Text(url.absoluteString)
										.font(.system(size: 15, weight: .regular))
										.foregroundStyle(Color(uiColor: .secondaryLabel))
										.lineLimit(1)
										.truncationMode(.tail)
								}

								Spacer(minLength: 8)

								ZagActionPill(
									title: .localized("Add"),
									backgroundColor: pillBackground
								) {
									Storage.shared.addSource(
										url,
										repository: source
									) { _ in
										_refreshFilteredRecommendedSourcesData()
									}
								}
							}
							.listRowSeparator(.hidden)
							.overlay(alignment: .bottom) {
								if url != _filteredRecommendedSourcesData.last?.url {
									Rectangle()
										.fill(separatorColor)
										.frame(height: 3.0 / UIScreen.main.scale)
										.padding(.horizontal, 16)
								}
							}
						}
					}
				} header: {
					Text(.localized("Featured"))
						.font(.headline)
						.foregroundStyle(.secondary)
						.textCase(nil)
				} footer: {
					Text(
						.localized(
							"Suggest a repository for Zag Featured through the Zag Store project."
						)
					)
					.font(.subheadline)
					.foregroundStyle(.secondary)
				}
			}
			.scrollContentBackground(.hidden)
			.background(popupBackground)
			.toolbar {
				NBToolbarButton(
					role: .cancel
				)

				NBToolbarButton(
					.localized("Add"),
					style: .text,
					placement: .confirmationAction,
					isDisabled: _sourceURL.isEmpty
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
		let dataService = _dataService

		return await withTaskGroup(
			of: (url: URL, data: ASRepository)?.self,
			returning: [(url: URL, data: ASRepository)].self
		) { group in
			for url in urls {
				group.addTask {
					await withCheckedContinuation { continuation in
						dataService.fetch(from: url) {
							(result: RepositoryDataHandler) in

							switch result {
							case .success(let repository):
								continuation.resume(
									returning: (url: url, data: repository)
								)

							case .failure(let error):
								Logger.misc.error(
									"Failed to fetch \(url): \(error.localizedDescription)"
								)
								continuation.resume(returning: nil)
							}
						}
					}
				}
			}

			var results: [(url: URL, data: ASRepository)] = []
			for await result in group {
				if let result {
					results.append(result)
				}
			}
			return results
		}
	}
}

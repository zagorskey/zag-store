//
//  SourcesView.swift
//  Zag Store
//
//  Created by samara on 10.04.2025.
//

import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews

// MARK: - View

struct SourcesView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	#if !NIGHTLY && !DEBUG
		@AppStorage("Feather.shouldStar")
		private var _shouldStar: Int = 0
	#endif

	@StateObject var viewModel = SourcesViewModel.shared

	@State private var _isAddingPresenting = false
	@State private var _addingSourceLoading = false
	@State private var _searchText = ""
	@State private var _selectedSearchRoute: SourceAppsView.SourceAppRoute?

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [
			NSSortDescriptor(
				keyPath: \AltSource.name,
				ascending: true
			)
		],
		animation: .snappy
	)
	private var _sources: FetchedResults<AltSource>


	// MARK: - Search

	private var _trimmedSearchText: String {
		_searchText.trimmingCharacters(
			in: .whitespacesAndNewlines
		)
	}

	private var _isSearchingApps: Bool {
		_trimmedSearchText.count >= 2
	}

	private var _filteredSources: [AltSource] {
		guard !_trimmedSearchText.isEmpty else {
			return Array(_sources)
		}

		return _sources.filter {
			$0.name?.localizedCaseInsensitiveContains(
				_trimmedSearchText
			) ?? false
		}
	}

	private var _matchingApps: [SourceAppsView.SourceAppRoute] {
		guard _isSearchingApps else {
			return []
		}

		var results: [SourceAppsView.SourceAppRoute] = []

		for source in _sources {
			guard let repository = viewModel.sources[source] else {
				continue
			}

			for app in repository.apps {
				guard app.currentName.localizedCaseInsensitiveContains(
					_trimmedSearchText
				) else {
					continue
				}

				results.append(
					SourceAppsView.SourceAppRoute(
						source: repository,
						app: app
					)
				)
			}
		}

		return results.sorted {
			$0.app.currentName.localizedCaseInsensitiveCompare(
				$1.app.currentName
			) == .orderedAscending
		}
	}


	// MARK: - Body

	var body: some View {
		NBNavigationView(.localized("Sources")) {
			NBListAdaptable {
				if _isSearchingApps {
					searchResultsContent
				} else {
					normalSourcesContent
				}
			}
			.searchable(
				text: $_searchText,
				placement: .platform(),
				prompt: "Search apps and repositories"
			)
			.overlay {
				emptyState
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button {
						Task {
							await viewModel.fetchSources(
								_sources,
								refresh: true
							)
						}
					} label: {
						ZStack {
							if viewModel.isRefreshing {
								ProgressView()
									.controlSize(.regular)
							} else {
								Image(
									systemName: "arrow.clockwise"
								)
								.font(
									.system(
										size: 17,
										weight: .semibold
									)
								)
							}
						}
						.frame(width: 22, height: 22)
					}
					.disabled(viewModel.isRefreshing)
					.accessibilityLabel(
						viewModel.isRefreshing
							? "Refreshing Repositories"
							: "Refresh Repositories"
					)
				}

				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing,
					isDisabled: _addingSourceLoading
				) {
					_isAddingPresenting = true
				}
			}
			.refreshable {
				await viewModel.fetchSources(
					_sources,
					refresh: true
				)
			}
			.sheet(isPresented: $_isAddingPresenting) {
				SourcesAddView()
			}
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
		}
		.navigationDestinationIfAvailable(
			item: $_selectedSearchRoute
		) { route in
			SourceAppsDetailView(
				source: route.source,
				app: route.app
			)
		}
		#if !NIGHTLY && !DEBUG
		.onAppear {
			guard _shouldStar < 6 else { return }
			_shouldStar += 1

			guard _shouldStar == 6 else { return }

			let github = UIAlertAction(
				title: "GitHub",
				style: .default
			) { _ in
				UIApplication.open(
					"https://github.com/khcrysalis/Feather"
				)
			}

			let cancel = UIAlertAction(
				title: .localized("Dismiss"),
				style: .cancel
			)

			UIAlertController.showAlert(
				title: .localized(
					"Enjoying %@?",
					arguments: Bundle.main.name
				),
				message: .localized(
					"Go to our GitHub and give us a star!"
				),
				actions: [github, cancel]
			)
		}
		#endif
	}


	// MARK: - Normal Sources

	@ViewBuilder
	private var normalSourcesContent: some View {
		if !_filteredSources.isEmpty {
			Section {
				NavigationLink {
					SourceAppsView(
						object: Array(_sources),
						viewModel: viewModel
					)
				} label: {
					let isRegular =
						horizontalSizeClass != .compact

					HStack(spacing: 18) {
						Image("Repositories")
							.appIconStyle()

						NBTitleWithSubtitleView(
							title: .localized(
								"All Repositories"
							),
							subtitle: .localized(
								"See all apps from your sources"
							)
						)
					}
					.padding(isRegular ? 12 : 0)
					.background(
						isRegular
							? RoundedRectangle(
								cornerRadius: 18,
								style: .continuous
							)
							.fill(
								Color(
									.quaternarySystemFill
								)
							)
							: nil
					)
				}
				.buttonStyle(.plain)
			}

			Section {
				ForEach(_filteredSources) { source in
					SourcesCellView(
						source: source,
						repository:
							viewModel.sources[source]
					)
					.background {
						NavigationLink {
							SourceAppsView(
								object: [source],
								viewModel: viewModel
							)
						} label: {
							EmptyView()
						}
						.opacity(0)
					}
				}
			} header: {
				ZagRepositoriesHeader(
					count: _filteredSources.count
				)
			}
		}
	}


	// MARK: - Global Search Results

	@ViewBuilder
	private var searchResultsContent: some View {
		if !_matchingApps.isEmpty {
			Section {
				ForEach(_matchingApps) { route in
					Button {
						_selectedSearchRoute = route
					} label: {
						SourceAppsCellView(
							source: route.source,
							app: route.app
						)
					}
					.buttonStyle(.plain)
				}
			} header: {
				HStack {
					Text("Apps")

					Spacer()

					ZagCountBadge(
						count: _matchingApps.count
					)
				}
			}
		}

		if !_filteredSources.isEmpty {
			Section {
				ForEach(_filteredSources) { source in
					SourcesCellView(
						source: source,
						repository:
							viewModel.sources[source]
					)
					.background {
						NavigationLink {
							SourceAppsView(
								object: [source],
								viewModel: viewModel
							)
						} label: {
							EmptyView()
						}
						.opacity(0)
					}
				}
			} header: {
				ZagRepositoriesHeader(
					count: _filteredSources.count
				)
			}
		}
	}


	// MARK: - Empty State

	@ViewBuilder
	private var emptyState: some View {
		if _sources.isEmpty {
			if #available(iOS 17, *) {
				ContentUnavailableView {
					Label(
						.localized("No Repositories"),
						systemImage: "globe.desk.fill"
					)
				} description: {
					Text(
						.localized(
							"Get started by adding your first repository."
						)
					)
				} actions: {
					Button {
						_isAddingPresenting = true
					} label: {
						NBButton(
							.localized("Add Source"),
							style: .text
						)
					}
				}
			}
		} else if _isSearchingApps &&
					_matchingApps.isEmpty &&
					_filteredSources.isEmpty {
			if #available(iOS 17, *) {
				ContentUnavailableView.search(
					text: _trimmedSearchText
				)
			}
		}
	}
}


// MARK: - Repository Count Header

private struct ZagRepositoriesHeader: View {
	let count: Int

	var body: some View {
		ZagSectionHeader(
			title: .localized("Repositories"),
			count: count
		)
	}
}

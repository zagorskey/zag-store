//
//  SourcesView.swift
//  Feather
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
		@AppStorage("Feather.shouldStar") private var _shouldStar: Int = 0
	#endif
	@StateObject var viewModel = SourcesViewModel.shared
	@State private var _isAddingPresenting = false
	@State private var _addingSourceLoading = false
	@State private var _searchText = ""
	
	private var _filteredSources: [AltSource] {
		_sources.filter { _searchText.isEmpty || ($0.name?.localizedCaseInsensitiveContains(_searchText) ?? false) }
	}
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Sources")) {
			NBListAdaptable {
				if !_filteredSources.isEmpty {
					Section {
						NavigationLink {
							SourceAppsView(object: Array(_sources), viewModel: viewModel)
						} label: {
							let isRegular = horizontalSizeClass != .compact
							HStack(spacing: 18) {
								Image("Repositories").appIconStyle()
								NBTitleWithSubtitleView(
									title: .localized("All Repositories"),
									subtitle: .localized("See all apps from your sources")
								)
							}
							.padding(isRegular ? 12 : 0)
							.background(
								isRegular
									? RoundedRectangle(cornerRadius: 18, style: .continuous)
									.fill(Color(.quaternarySystemFill))
									: nil
							)
						}
						.buttonStyle(.plain)
					}
					
					Section {
						ForEach(_filteredSources) { source in
							NavigationLink {
								SourceAppsView(object: [source], viewModel: viewModel)
							} label: {
								SourcesCellView(source: source)
							}
							.buttonStyle(.plain)
						}
					} header: {
						ZagRepositoriesHeader(
							count: _filteredSources.count
						)
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
			.overlay {
				if _filteredSources.isEmpty {
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Repositories"), systemImage: "globe.desk.fill")
						} description: {
							Text(.localized("Get started by adding your first repository."))
						} actions: {
							Button {
								_isAddingPresenting = true
							} label: {
								NBButton(.localized("Add Source"), style: .text)
							}
						}
					}
				}
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
								Image(systemName: "arrow.clockwise")
									.font(.system(size: 17, weight: .semibold))
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
				await viewModel.fetchSources(_sources, refresh: true)
			}
			.sheet(isPresented: $_isAddingPresenting) {
				SourcesAddView()
			}
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
		}
		#if !NIGHTLY && !DEBUG
		.onAppear {
				guard _shouldStar < 6 else { return }; _shouldStar += 1
				guard _shouldStar == 6 else { return }
			
				let github = UIAlertAction(title: "GitHub", style: .default) { _ in
					UIApplication.open("https://github.com/khcrysalis/Feather")
				}
			
				let cancel = UIAlertAction(title: .localized("Dismiss"), style: .cancel)
			
				UIAlertController.showAlert(
					title: .localized("Enjoying %@?", arguments: Bundle.main.name),
					message: .localized("Go to our GitHub and give us a star!"),
					actions: [github, cancel]
				)
			}
		#endif
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

private struct ZagRepositoriesCountBadge: View {
	let count: Int

	var body: some View {
		Text(count.description)
			.font(.system(size: 14, weight: .bold))
			.foregroundStyle(Color.white)
			.frame(width: 22, height: 22)
			.background(
				Circle()
					.fill(Color.red)
			)
	}
}

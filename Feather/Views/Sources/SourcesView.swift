//
//  SourcesView.swift
//  Zag Store
//
//  Created by samara on 10.04.2025.
//
import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews
import UIKit
import UniformTypeIdentifiers
import Speech
import AVFoundation
// MARK: - Zag Sources Atom Icon

struct ZagSourcesAtomIcon: View {
	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#3F8EF7"

	var animated: Bool = false
	@State private var drawOut = false

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 11, style: .continuous)
				.fill(Color(hex: themeColorHex))
				.overlay {
					RoundedRectangle(cornerRadius: 11, style: .continuous)
						.stroke(Color.primary.opacity(0.16), lineWidth: 1)
				}

			if #available(iOS 26.0, *) {
				Image(systemName: "atom")
					.font(.system(size: 39, weight: .regular))
					.foregroundStyle(.white)
					.symbolEffect(
						.drawOff.wholeSymbol,
						options: .nonRepeating,
						isActive: drawOut
					)
					.task(id: animated) {
						guard animated else {
							drawOut = false
							return
						}

						// Keep the symbol visible for the first rendered frame,
						// then immediately begin by drawing it out.
						drawOut = false
						await Task.yield()
						guard !Task.isCancelled && animated else { return }
						drawOut = true

						while !Task.isCancelled && animated {
							try? await Task.sleep(for: .seconds(1.15))
							guard !Task.isCancelled && animated else { break }
							drawOut.toggle()
						}
					}
			} else {
				Image(systemName: "atom")
					.font(.system(size: 39, weight: .regular))
					.foregroundStyle(.white)
			}
		}
		.frame(width: 62, height: 62)
	}
}

struct ZagSourcesTabIcon: View {
	var body: some View {
		Image(systemName: "atom")
	}
}

// MARK: - View
struct SourcesView: View {
	@Environment(\.horizontalSizeClass)
	private var horizontalSizeClass
	#if !NIGHTLY && !DEBUG
	@AppStorage("Feather.shouldStar")
	private var _shouldStar: Int = 0
	#endif
	@StateObject var viewModel =
		SourcesViewModel.shared
	@State private var _isAddingPresenting = false
	@State private var _addingSourceLoading = false
	@State private var _searchText = ""
	@State private var _dictationAvailable = false
	@FocusState private var _searchFieldFocused: Bool
	@State private var _isImportingRepositories = false
	@State private var _isImportingRepositoryFile = false
	@AppStorage("zagStore.sources.sortMode") private var _sortModeRaw = "default"
	@AppStorage("zagStore.sources.customOrder") private var _customOrderData = ""
	@State private var _isRearrangingRepositories = false
	@State private var _showAllRepositories = false
	@State private var _loadingAppsDotCount = 0
	@State private var _selectedSearchRoute:
		SourceAppsView.SourceAppRoute?
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
	private var _sources:
		FetchedResults<AltSource>
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
	private enum RepositorySortMode: String {
		case defaultOrder = "default"
		case nameAscending
		case nameDescending
		case lastUpdated
		case dateAdded
		case custom
	}
	private var _sortMode: RepositorySortMode {
		RepositorySortMode(rawValue: _sortModeRaw) ?? .defaultOrder
	}
	private var _customOrder: [String] {
		_customOrderData.split(separator: "\n").map(String.init)
	}
	private func _sourceKey(_ source: AltSource) -> String {
		source.identifier ?? source.sourceURL?.absoluteString ?? source.objectID.uriRepresentation().absoluteString
	}
	private func _lastUpdated(_ source: AltSource) -> Date {
		viewModel.sources[source]?.apps.compactMap { $0.currentDate?.date }.max() ?? .distantPast
	}
	private func _sorted(_ sources: [AltSource]) -> [AltSource] {
		switch _sortMode {
		case .defaultOrder:
			return sources
		case .nameAscending:
			return sources.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
		case .nameDescending:
			return sources.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedDescending }
		case .lastUpdated:
			return sources.sorted { _lastUpdated($0) > _lastUpdated($1) }
		case .dateAdded:
			return sources.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
		case .custom:
			let order = Dictionary(uniqueKeysWithValues: _customOrder.enumerated().map { ($1, $0) })
			return sources.enumerated().sorted {
				let li = order[_sourceKey($0.element)] ?? (_customOrder.count + $0.offset)
				let ri = order[_sourceKey($1.element)] ?? (_customOrder.count + $1.offset)
				return li < ri
			}.map(\.element)
		}
	}
	private var _displayedSources: [AltSource] {
		_sorted(_filteredSources)
	}
	private func _selectSort(_ mode: RepositorySortMode) {
		_sortModeRaw = mode.rawValue
	}
	private func _beginRearranging() {
		var order = _customOrder
		for source in _sorted(Array(_sources)) {
			let key = _sourceKey(source)
			if !order.contains(key) { order.append(key) }
		}
		_customOrderData = order.joined(separator: "\n")
		_sortModeRaw = RepositorySortMode.custom.rawValue
		_isRearrangingRepositories = true
	}
	private func _moveRepositories(from offsets: IndexSet, to destination: Int) {
		var items = _displayedSources
		items.move(fromOffsets: offsets, toOffset: destination)
		_customOrderData = items.map(_sourceKey).joined(separator: "\n")
	}
	private func _finishReordering() {
		_isRearrangingRepositories = false
	}

	private var _matchingApps:
		[SourceAppsView.SourceAppRoute] {
		guard _isSearchingApps else {
			return []
		}
		var results:
			[SourceAppsView.SourceAppRoute] = []
		for source in _sources {
			guard
				let repository =
					viewModel.sources[source]
			else {
				continue
			}
			for app in repository.apps {
				guard
					app.currentName
						.localizedCaseInsensitiveContains(
							_trimmedSearchText
						)
				else {
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
			$0.app.currentName
				.localizedCaseInsensitiveCompare(
					$1.app.currentName
				) == .orderedAscending
		}
	}
	// MARK: - Body
	var body: some View {
		NBNavigationView(.localized("Sources")) {
			NBListAdaptable(transparentBackground: true) {
				Group {
				if _isSearchingApps {
					searchResultsContent
				} else {
					normalSourcesContent
				}
				}
				.listRowBackground(Color.clear)
			}
			.zagWallpaperSurface()
			.toolbarBackground(.hidden, for: .navigationBar)
			.searchable(
				text: $_searchText,
				placement: .platform(),
				prompt: Text("Repos, Apps, Games and More")
			)
			.modifier(
				ZagRepositorySearchFocusModifier(
					isFocused: $_searchFieldFocused
				)
			)
			.background {
				ZagNativeSearchMicInstaller(
					isAvailable: _dictationAvailable,
					action: _startDictationFromSearchMic,
					prompt: "Repos, Apps, Games and More",
					activePrompt: "Repos, Apps and More"
				)
				.frame(width: 0, height: 0)
			}
			.overlay {
				emptyState
			}
			.environment(\.editMode, .constant(_isRearrangingRepositories ? .active : .inactive))
			.toolbar {
				ToolbarItemGroup(
					placement: .topBarLeading
				) {
					repositorySortMenu
					refreshButton
				}
				ToolbarItemGroup(
					placement: .topBarTrailing
				) {
					addRepositoryButton
					repositoryTransferMenu
				}
			}
			.refreshable {
				await viewModel.fetchSources(
					_sources,
					refresh: true
				)
			}
			.sheet(
				isPresented:
					$_isAddingPresenting
			) {
				SourcesAddView()
			}
			.sheet(
				isPresented:
					$_isImportingRepositoryFile
			) {
				FileImporterRepresentableView(
					allowedContentTypes: [
						UTType(
							filenameExtension: "zagrepos"
						) ?? .data,
						.json,
						.plainText
					],
					allowsMultipleSelection: false,
					onDocumentsPicked: { urls in
						handleRepositoryFileImport(
							.success(urls)
						)
					}
				)
				.ignoresSafeArea()
			}
		}
		.onAppear {
			_probeSystemDictation()
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(
				_sources
			)
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
			guard _shouldStar < 6 else {
				return
			}
			_shouldStar += 1
			guard _shouldStar == 6 else {
				return
			}
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
				actions: [
					github,
					cancel
				]
			)
		}
		#endif
	}
	private func _probeSystemDictation() {
		guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
			  cls.responds(to: NSSelectorFromString("sharedInstance")),
			  let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
		else {
			_dictationAvailable = false
			return
		}
		_dictationAvailable = controller.responds(to: NSSelectorFromString("startDictation"))
	}

	private func _startDictationFromSearchMic() {
		_searchFieldFocused = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
			_startSystemDictation()
		}
	}

	private func _startSystemDictation() {
		guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
			  cls.responds(to: NSSelectorFromString("sharedInstance")),
			  let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
		else { return }

		let preheat = NSSelectorFromString("preheatIfNecessary")
		if controller.responds(to: preheat) { _ = controller.perform(preheat) }
		let start = NSSelectorFromString("startDictation")
		if controller.responds(to: start) { _ = controller.perform(start) }
	}

	// MARK: - Toolbar
	private var refreshButton: some View {
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
						systemName:
							"arrow.clockwise"
					)
					.font(
						.system(
							size: 17,
							weight: .semibold
						)
					)
				}
			}
			.frame(
				width: 22,
				height: 22
			)
		}
		.disabled(viewModel.isRefreshing)
		.accessibilityLabel(
			viewModel.isRefreshing
				? "Refreshing Repositories"
				: "Refresh Repositories"
		)
	}
	// MARK: Add Repository
	private var addRepositoryButton:
		some View {
		Button {
			_isAddingPresenting = true
		} label: {
			Image(systemName: "plus")
				.font(
					.system(
						size: 17,
						weight: .semibold
					)
				)
				.frame(
					width: 26,
					height: 22
				)
		}
		.disabled(_addingSourceLoading)
		.accessibilityLabel(
			"Add Repository"
		)
	}
	// MARK: Repository Sorting
	@ViewBuilder
	private var repositorySortMenu: some View {
		if _isRearrangingRepositories {
			Button {
				_finishReordering()
			} label: {
				Image(systemName: "checkmark")
					.font(.system(size: 19, weight: .semibold))
					.frame(width: 26, height: 22)
			}
			.accessibilityLabel("Done Reordering")
		} else {
			Menu {
				Button { _selectSort(.defaultOrder) } label: {
					Label("Default", systemImage: _sortMode == .defaultOrder ? "checkmark" : "ellipsis")
				}
				Button { _selectSort(.nameAscending) } label: {
					Label("Name (A–Z)", systemImage: _sortMode == .nameAscending ? "checkmark" : "chevron.down")
				}
				Button { _selectSort(.nameDescending) } label: {
					Label("Name (Z–A)", systemImage: _sortMode == .nameDescending ? "checkmark" : "chevron.up")
				}
				Button { _selectSort(.lastUpdated) } label: {
					Label("Last Updated", systemImage: _sortMode == .lastUpdated ? "checkmark" : "clock")
				}
				Button { _selectSort(.dateAdded) } label: {
					Label("Date Added", systemImage: _sortMode == .dateAdded ? "checkmark" : "calendar.badge.plus")
				}
				Button { _selectSort(.custom) } label: {
					Label("Custom", systemImage: _sortMode == .custom ? "checkmark" : "list.bullet")
				}
				Divider()
				Button { _beginRearranging() } label: {
					Label("Reorder", systemImage: "arrow.up.arrow.down")
				}
			} label: {
				Image(systemName: "line.3.horizontal.decrease")
					.font(.system(size: 19, weight: .semibold))
					.frame(width: 26, height: 22)
			}
			.accessibilityLabel("Sort Repositories")
		}
	}

	// MARK: Repository Transfer
	private var repositoryTransferMenu:
		some View {
		Menu {
			Button {
				_isImportingRepositoryFile =
					true
			} label: {
				Label(
					"Import File",
					systemImage:
						"square.and.arrow.down"
				)
			}
			Button {
				exportRepositoriesToFile()
			} label: {
				Label(
					"Export File",
					systemImage:
						"square.and.arrow.up"
				)
			}
			Divider()
			Button {
				importRepositoriesFromClipboard()
			} label: {
				Label(
					"From Clipboard",
					systemImage:
						"doc.on.clipboard"
				)
			}
			Button {
				RepositoryTransferManager
					.shared
					.copyRepositoriesToClipboard()
			} label: {
				Label(
					"To Clipboard",
					systemImage:
						"doc.on.doc"
				)
			}
		} label: {
			ZStack {
				if _isImportingRepositories {
					ProgressView()
						.controlSize(.regular)
				} else {
					Image(
						systemName:
							"arrow.up.arrow.down"
					)
					.font(
						.system(
							size: 17,
							weight: .semibold
						)
					)
				}
			}
			.frame(
				width: 26,
				height: 22
			)
		}
		.disabled(_isImportingRepositories)
		.accessibilityLabel(
			"Repository Transfer"
		)
	}
	// MARK: - Repository Transfer Actions
	private func importRepositoriesFromClipboard() {
		_isImportingRepositories = true
		RepositoryTransferManager.shared
			.importRepositories(
				from:
					UIPasteboard.general.string
			) { _ in
				_isImportingRepositories =
					false
				Task {
					await viewModel.fetchSources(
						_sources,
						refresh: true
					)
				}
			}
	}
	private func exportRepositoriesToFile() {
		guard
			let url =
				RepositoryTransferManager
					.shared
					.makeExportFile()
		else {
			return
		}
		presentRepositoryShareSheet(
			for: url
		)
	}
	@MainActor
	private func presentRepositoryShareSheet(
		for url: URL
	) {
		guard
			let scene = UIApplication.shared.connectedScenes
				.compactMap({ $0 as? UIWindowScene })
				.first(where: { $0.activationState == .foregroundActive }),
			let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
		else {
			return
		}

		var presenter = root
		while let presented = presenter.presentedViewController {
			presenter = presented
		}

		let controller = UIActivityViewController(
			activityItems: [url],
			applicationActivities: nil
		)

		if let popover = controller.popoverPresentationController {
			popover.sourceView = presenter.view
			popover.sourceRect = CGRect(
				x: presenter.view.bounds.midX,
				y: presenter.view.bounds.midY,
				width: 1,
				height: 1
			)
			popover.permittedArrowDirections = []
		}

		presenter.present(controller, animated: true)
	}

	private func handleRepositoryFileImport(
		_ result:
			Result<[URL], Error>
	) {
		switch result {
		case .success(let urls):
			guard let url = urls.first else {
				return
			}
			_isImportingRepositories = true
			RepositoryTransferManager.shared
				.importRepositories(
					fromFile: url
				) { _ in
					_isImportingRepositories =
						false
					Task {
						await viewModel
							.fetchSources(
								_sources,
								refresh: true
							)
					}
				}
		case .failure(let error):
			UIAlertController.showAlertWithOk(
				title: .localized("Error"),
				message:
					error.localizedDescription
			)
		}
	}
	// MARK: - Normal Sources
	@ViewBuilder
	private var normalSourcesContent:
		some View {
		if !_filteredSources.isEmpty {
			Section {
				Button {
					_showAllRepositories = true
				} label: {
					let isRegular =
						horizontalSizeClass
							!= .compact
					HStack(spacing: 10) {
						ZagSourcesAtomIcon(animated: viewModel.isRefreshing)

						VStack(
							alignment: .leading,
							spacing: 2
						) {
							Text(
								.localized(
									"Your Repositories"
								)
							)
							.font(
								.system(
									size: 20,
									weight: .regular
								)
							)
							.foregroundStyle(.primary)

							let totalApps = viewModel.sources.values.reduce(0) {
								$0 + $1.apps.count
							}
							if viewModel.isRefreshing {
								Text("Loading apps" + String(repeating: ".", count: _loadingAppsDotCount))
									.font(.system(size: 15, weight: .regular))
									.foregroundColor(Color(uiColor: .secondaryLabel))
									.lineLimit(1)
									.task(id: viewModel.isRefreshing) {
										_loadingAppsDotCount = 0
										while !Task.isCancelled && viewModel.isRefreshing {
											try? await Task.sleep(for: .milliseconds(380))
											guard !Task.isCancelled && viewModel.isRefreshing else { break }
											_loadingAppsDotCount = (_loadingAppsDotCount + 1) % 4
										}
									}
							} else if totalApps == 0 {
								HStack(spacing: 0) {
									Text("You have ")
										.foregroundColor(Color(uiColor: .secondaryLabel))
									Text("0")
										.fontWeight(.semibold)
										.foregroundColor(.red)
									Text(" apps")
										.foregroundColor(Color(uiColor: .secondaryLabel))
								}
								.font(.system(size: 15, weight: .regular))
								.lineLimit(1)
							} else {
								HStack(spacing: 0) {
									Text("See all ")
										.foregroundColor(Color(uiColor: .secondaryLabel))
									Text(totalApps.formatted())
										.fontWeight(.semibold)
										.foregroundColor(.green)
									Text(totalApps == 1 ? " app from sources" : " apps from sources")
										.foregroundColor(Color(uiColor: .secondaryLabel))
								}
								.font(.system(size: 15, weight: .regular))
								.lineLimit(1)
							}
						}
						.frame(
							maxWidth: .infinity,
							alignment: .leading
						)

						Image(systemName: "chevron.right")
							.font(.system(size: 20, weight: .bold))
							.foregroundStyle(Color(uiColor: .systemGray2))
					}
					.padding(
						isRegular ? 12 : 0
					)
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
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
			.navigationDestination(
				isPresented: $_showAllRepositories
			) {
				SourceAppsView(
					object: Array(_sources),
					viewModel: viewModel
				)
			}
			.listSectionSeparator(.hidden, edges: .all)
			Section {
				ZagRepositoriesHeader(
					count: _displayedSources.count
				)
				.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)

				ForEach(
					_displayedSources
				) { source in
					SourcesCellView(
						source: source,
						repository:
							viewModel.sources[
								source
							],
						isRefreshing: viewModel.isRefreshing
					)
					.moveDisabled(!_isRearrangingRepositories)
					.background {
						NavigationLink {
							SourceAppsView(
								object: [
									source
								],
								viewModel:
									viewModel
							)
						} label: {
							EmptyView()
						}
						.opacity(0)
					}
				}
				.onMove(perform: _isRearrangingRepositories ? _moveRepositories : nil)
			}
		}
	}
	// MARK: - Global Search Results
	@ViewBuilder
	private var searchResultsContent:
		some View {
		if !_matchingApps.isEmpty {
			Section {
				HStack {
					Text("Apps")
					Spacer()
					ZagCountBadge(count: _matchingApps.count)
				}
				.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)

				ForEach(
					_matchingApps
				) { route in
					Button {
						_selectedSearchRoute =
							route
					} label: {
						SourceAppsCellView(
							source:
								route.source,
							app:
								route.app
						)
					}
					.buttonStyle(.plain)
				}
			}
		}
		if !_filteredSources.isEmpty {
			Section {
				ZagRepositoriesHeader(
					count: _displayedSources.count
				)
				.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)

				ForEach(
					_displayedSources
				) { source in
					SourcesCellView(
						source: source,
						repository:
							viewModel.sources[
								source
							],
						isRefreshing: viewModel.isRefreshing
					)
					.background {
						NavigationLink {
							SourceAppsView(
								object: [
									source
								],
								viewModel:
									viewModel
							)
						} label: {
							EmptyView()
						}
						.opacity(0)
					}
				}
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
						.localized(
							"No Repositories"
						),
						systemImage:
							"globe.desk.fill"
					)
				} description: {
					Text(
						.localized(
							"Get started by adding your first repository."
						)
					)
				} actions: {
					Button {
						_isAddingPresenting =
							true
					} label: {
						ZagActionPill(title: .localized("Add Source")) {
							_isAddingPresenting = true
						}
					}
				}
			}
		} else if
			_isSearchingApps &&
			_matchingApps.isEmpty &&
			_filteredSources.isEmpty
		{
			if #available(iOS 17, *) {
				ContentUnavailableView.search(
					text:
						_trimmedSearchText
				)
			}
		}
	}
}
// MARK: - Zag Store Liquid Glass Search

struct ZagLiquidGlassSearchBar: View {
	@Binding var text: String
	@Binding var isActive: Bool
	var isPinned: Bool = false
	var prompt: String = "Repos, Apps, Games and More"
	var activePrompt: String? = "Repos, Apps and More"

	@Environment(\.scenePhase)
	private var scenePhase

	@FocusState
	private var isFocused: Bool

	@StateObject
	private var speech = ZagSpeechRecognizer()

	var body: some View {
		HStack(spacing: 10) {
			HStack(spacing: 10) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 19, weight: .regular))
					.foregroundStyle(.primary)

				ZStack(alignment: .leading) {
					if text.isEmpty {
						Text(isActive ? (activePrompt ?? prompt) : prompt)
							.font(.system(size: 19, weight: .semibold))
							.foregroundStyle(Color(uiColor: .placeholderText))
							.lineLimit(1)
							.allowsHitTesting(false)
					}

					TextField("", text: $text)
						.focused($isFocused)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.submitLabel(.search)
				}

				Button {
					if speech.isListening {
						speech.stop()
					} else {
						isActive = true
						isFocused = true
						speech.start { transcript in
							text = transcript
						}
					}
				} label: {
					Image(
						systemName:
							speech.isListening
								? "waveform"
								: "mic.fill"
					)
					.font(.system(size: 21, weight: .regular))
					.foregroundStyle(.primary)
					.frame(width: 28, height: 28)
				}
				.buttonStyle(.plain)
				.accessibilityLabel(
					speech.isListening
						? "Stop Dictation"
						: "Start Dictation"
				)

				if isActive && !text.isEmpty {
					Button {
						text = ""
					} label: {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 17))
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Clear Search")
				}
			}
			.padding(.horizontal, 16)
			.frame(height: 50)
			.zagSearchBackground(isGlass: isActive || isPinned)

			Button {
				closeSearch()
			} label: {
				Image(systemName: "xmark")
					.font(.system(size: 22, weight: .semibold))
					.foregroundStyle(Color.white)
					.frame(width: 50, height: 50)
					.zagSearchGlass()
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Close Search")
			.frame(width: isActive ? 50 : 0, alignment: .trailing)
			.opacity(isActive ? 1 : 0)
			.scaleEffect(isActive ? 1 : 0.86, anchor: .trailing)
			.clipped()
			.allowsHitTesting(isActive)
		}
		.animation(
			.interpolatingSpring(stiffness: 300, damping: 30),
			value: isActive
		)
		.onChange(of: isFocused) { focused in
			if focused {
				isActive = true
			}
		}
		.onChange(of: isActive) { active in
			if !active {
				isFocused = false
				speech.stop()
			}
		}
		.onChange(of: scenePhase) { phase in
			if phase != .active {
				speech.stop()
				isFocused = false
				isActive = false
			}
		}
		.onDisappear {
			speech.stop()
			isFocused = false
			isActive = false
		}
	}

	private func closeSearch() {
		speech.stop()
		isFocused = false
		isActive = false
	}
}

private struct ZagSearchPinTrackingModifier: ViewModifier {
	@Binding var isPinned: Bool

	@ViewBuilder
	func body(content: Content) -> some View {
		if #available(iOS 18.0, *) {
			content.onScrollGeometryChange(
				for: Bool.self,
				of: { geometry in
					geometry.contentOffset.y + geometry.contentInsets.top >= 48
				},
				action: { _, pinned in
					if isPinned != pinned {
						withAnimation(.snappy(duration: 0.25)) {
							isPinned = pinned
						}
					}
				}
			)
		} else {
			content
		}
	}
}

extension View {
	func zagTrackSearchPin(_ isPinned: Binding<Bool>) -> some View {
		modifier(ZagSearchPinTrackingModifier(isPinned: isPinned))
	}

	@ViewBuilder
	func zagSearchBackground(isGlass: Bool) -> some View {
		if isGlass {
			self.zagSearchGlass()
		} else {
			self
				.background(
					Color(
						uiColor: UITraitCollection.current.userInterfaceStyle == .dark
							? UIColor.systemGray6
							: UIColor.systemGray6
					),
					in: Capsule()
				)
		}
	}

	@ViewBuilder
	func zagSearchGlass() -> some View {
		if #available(iOS 26.0, *) {
			self.glassEffect(
				.regular.interactive(),
				in: Capsule()
			)
		} else {
			self
				.background(
					.ultraThinMaterial,
					in: Capsule()
				)
				.overlay {
					Capsule()
						.strokeBorder(
							Color.primary.opacity(0.08),
							lineWidth: 0.5
						)
				}
		}
	}
}

@MainActor
final class ZagSpeechRecognizer: ObservableObject {
	@Published private(set)
	var isListening = false

	private let recognizer = SFSpeechRecognizer()
	private var request:
		SFSpeechAudioBufferRecognitionRequest?
	private var recognitionTask:
		SFSpeechRecognitionTask?
	private let audioEngine = AVAudioEngine()
	private var transcriptHandler: ((String) -> Void)?
	private var silenceTask: Task<Void, Never>?

	func start(
		onTranscript: @escaping (String) -> Void
	) {
		if isListening {
			stop()
			return
		}

		transcriptHandler = onTranscript

		SFSpeechRecognizer.requestAuthorization { status in
			Task { @MainActor in
				guard status == .authorized else {
					self.stop()
					return
				}

				AVAudioSession.sharedInstance()
					.requestRecordPermission { granted in
						Task { @MainActor in
							guard granted else {
								self.stop()
								return
							}

							self.beginRecognition()
						}
					}
			}
		}
	}

	private func beginRecognition() {
		stopAudioOnly()

		guard
			let recognizer,
			recognizer.isAvailable
		else {
			return
		}

		let session = AVAudioSession.sharedInstance()

		do {
			try session.setCategory(
				.record,
				mode: .measurement,
				options: .duckOthers
			)
			try session.setActive(
				true,
				options: .notifyOthersOnDeactivation
			)

			let request =
				SFSpeechAudioBufferRecognitionRequest()

			request.shouldReportPartialResults = true
			self.request = request

			let input = audioEngine.inputNode
			let format = input.outputFormat(forBus: 0)

			input.removeTap(onBus: 0)
			input.installTap(
				onBus: 0,
				bufferSize: 1024,
				format: format
			) { buffer, _ in
				request.append(buffer)
			}

			recognitionTask = recognizer
				.recognitionTask(with: request) {
					[weak self] result, error in

					guard let self else {
						return
					}

					Task { @MainActor in
						if let result {
							self.transcriptHandler?(
								result.bestTranscription
									.formattedString
							)

							self.scheduleSilenceStop()
						}

						if error != nil ||
							result?.isFinal == true {
							self.stop()
						}
					}
				}

			audioEngine.prepare()
			try audioEngine.start()
			isListening = true

			scheduleInitialTimeout()
		} catch {
			stop()
		}
	}

	private func scheduleInitialTimeout() {
		silenceTask?.cancel()
		silenceTask = Task { [weak self] in
			try? await Task.sleep(
				for: .seconds(8)
			)

			guard !Task.isCancelled else {
				return
			}

			await MainActor.run {
				self?.stop()
			}
		}
	}

	private func scheduleSilenceStop() {
		silenceTask?.cancel()
		silenceTask = Task { [weak self] in
			try? await Task.sleep(
				for: .seconds(1.8)
			)

			guard !Task.isCancelled else {
				return
			}

			await MainActor.run {
				self?.stop()
			}
		}
	}

	private func stopAudioOnly() {
		silenceTask?.cancel()
		silenceTask = nil

		if audioEngine.isRunning {
			audioEngine.stop()
		}

		audioEngine.inputNode.removeTap(
			onBus: 0
		)

		request?.endAudio()
		recognitionTask?.cancel()
		recognitionTask = nil
		request = nil
		isListening = false

		try? AVAudioSession.sharedInstance()
			.setActive(
				false,
				options: .notifyOthersOnDeactivation
			)
	}

	func stop() {
		stopAudioOnly()
	}
}

// MARK: - Repository Count Header
private struct ZagRepositoriesHeader:
	View {
	let count: Int
	var body: some View {
		ZagSectionHeader(
			title: .localized(
				"Repositories"
			),
			count: count
		)
	}
}

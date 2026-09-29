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
	@State private var _searchActive = false
	@State private var _isImportingRepositories = false
	@State private var _isImportingRepositoryFile = false
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
			NBListAdaptable {
				if _isSearchingApps {
					searchResultsContent
				} else {
					normalSourcesContent
				}
			}
			.safeAreaInset(edge: .top, spacing: 8) {
				ZagLiquidGlassSearchBar(
					text: $_searchText,
					isActive: $_searchActive
				)
					.padding(.horizontal, 16)
					.padding(.top, 4)
			}
			.toolbar(
				_searchActive ? .hidden : .visible,
				for: .navigationBar
			)
			.overlay {
				emptyState
			}
			.toolbar {
				ToolbarItem(
					placement: .topBarLeading
				) {
					refreshButton
				}
				ToolbarItemGroup(
					placement: .topBarTrailing
				) {
					// Primary action first:
					// + | transfer
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
				NavigationLink {
					SourceAppsView(
						object:
							Array(_sources),
						viewModel: viewModel
					)
				} label: {
					let isRegular =
						horizontalSizeClass
							!= .compact
					HStack(spacing: 10) {
						Image(systemName: "globe")
							.resizable()
							.scaledToFit()
							.frame(width: 42, height: 42)
							.foregroundStyle(.primary)
							.frame(width: 62, height: 62)

						VStack(
							alignment: .leading,
							spacing: 2
						) {
							Text(
								.localized(
									"All Repositories"
								)
							)
							.font(
								.system(
									size: 17,
									weight: .regular
								)
							)
							.foregroundStyle(.primary)

							Text(
								.localized(
									"See all apps from your sources"
								)
							)
							.font(.subheadline)
							.foregroundStyle(.secondary)
						}
						.frame(
							maxWidth: .infinity,
							alignment: .leading
						)
					}
					.padding(
						isRegular ? 12 : 0
					)
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
				ForEach(
					_filteredSources
				) { source in
					SourcesCellView(
						source: source,
						repository:
							viewModel.sources[
								source
							]
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
			} header: {
				ZagRepositoriesHeader(
					count:
						_filteredSources.count
				)
			}
		}
	}
	// MARK: - Global Search Results
	@ViewBuilder
	private var searchResultsContent:
		some View {
		if !_matchingApps.isEmpty {
			Section {
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
			} header: {
				HStack {
					Text("Apps")
					Spacer()
					ZagCountBadge(
						count:
							_matchingApps
								.count
					)
				}
			}
		}
		if !_filteredSources.isEmpty {
			Section {
				ForEach(
					_filteredSources
				) { source in
					SourcesCellView(
						source: source,
						repository:
							viewModel.sources[
								source
							]
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
			} header: {
				ZagRepositoriesHeader(
					count:
						_filteredSources.count
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
						NBButton(
							.localized(
								"Add Source"
							),
							style: .text
						)
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
	var prompt: String = "Repos, Apps and More"

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
					.font(.system(size: 19, weight: .medium))
					.foregroundStyle(Color.white)

				ZStack(alignment: .leading) {
					if text.isEmpty {
						Text(prompt)
							.fontWeight(.semibold)
							.foregroundStyle(Color.white)
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
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(Color.white)
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
			.zagSearchGlass()

			if isActive {
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
				.transition(.scale.combined(with: .opacity))
			}
		}
		.animation(.snappy, value: isActive)
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

extension View {
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

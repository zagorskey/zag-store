//



//  ContentView.swift



//  Feather



//



//  Created by samara on 10.04.2025.



//







import SwiftUI



import CoreData



import NimbleViews



import NukeUI







// MARK: - View



struct LibraryView: View {



	@StateObject var downloadManager = DownloadManager.shared



	@StateObject private var sourcesViewModel = SourcesViewModel.shared



	@StateObject private var updateManager = UpdateManager.shared










	@State private var _selectedInfoAppPresenting: AnyApp?



	@State private var _selectedSigningAppPresenting: AnyApp?



	@State private var _selectedInstallAppPresenting: AnyApp?



	@State private var _isImportingPresenting = false



	@State private var _isDownloadingPresenting = false



	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting







	// MARK: Selection State



	@State private var _selectedAppUUIDs: Set<String> = []



	@State private var _editMode: EditMode = .inactive







	@State private var _searchText = ""

	@State private var _searchActive = false



	@State private var _selectedScope: Scope = .all











	@Namespace private var _namespace







	// horror



	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {



		apps.filter {



			_searchText.isEmpty ||



				(($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)



		}



	}







	private var _filteredSignedApps: [Signed] {



		filteredAndSortedApps(from: _signedApps)



	}







	private var _filteredImportedApps: [Imported] {



		filteredAndSortedApps(from: _importedApps)



	}







	// MARK: Fetch



	@FetchRequest(



		entity: Signed.entity(),



		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],



		animation: .snappy



	) private var _signedApps: FetchedResults<Signed>







	@FetchRequest(



		entity: Imported.entity(),



		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],



		animation: .snappy



	) private var _importedApps: FetchedResults<Imported>







	// MARK: Body



	@ViewBuilder
	private var zagUpdatesContent: some View {
		if !updateManager.updates.isEmpty {
			ZagUpdatesSection(
				updates: updateManager.updates,
				onPreparedForInstall: handlePreparedUpdate
			)
		}
	}

	private func handlePreparedUpdate(_ signedUUID: String) {
		guard let signed = ZagUpdateTransactionManager.shared.signedApp(
			uuid: signedUUID
		) else {
			return
		}

		_selectedInstallAppPresenting = AnyApp(base: signed)
	}

	var body: some View {



		NBNavigationView(.localized("Apps")) {



			NBListAdaptable {



			zagUpdatesContent

			.compatSearchScopes($_selectedScope) {
				librarySearchScopes
			}



			.scrollDismissesKeyboard(.interactively)



			.overlay {



				if



					_filteredSignedApps.isEmpty,



					_filteredImportedApps.isEmpty



				{



				if #available(iOS 17, *) {



						ContentUnavailableView {



							Label(.localized("No Apps"), systemImage: "questionmark.app.fill")



						} description: {



							Text(.localized("Get started by importing your first IPA file."))



						} actions: {



							Menu {



								_importActions()



							} label: {



								NBButton(.localized("Import"), style: .text)



							}



						}



					}



				}



			}



			.toolbar {



				ToolbarItem(placement: .topBarLeading) {



					EditButton()



				}







				if _editMode.isEditing {



					NBToolbarButton(



						.localized("Delete"),



						systemImage: "trash",



						isDisabled: _selectedAppUUIDs.isEmpty



					) {



						_bulkDeleteSelectedApps()



					}



				} else {



					NBToolbarMenu(



						systemImage: "plus",



						style: .icon,



						placement: .topBarTrailing



					) {



						_importActions()



					}



				}



			}



			.environment(\.editMode, $_editMode)



			.sheet(item: $_selectedInfoAppPresenting) { app in



				LibraryInfoView(app: app.base)



			}



			.sheet(item: $_selectedInstallAppPresenting) { app in



				InstallPreviewView(app: app.base, isSharing: app.archive)



					.presentationDetents([.height(200)])



					.presentationDragIndicator(.visible)



			}



			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in



				SigningView(app: app.base)



					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)



			}



			.sheet(isPresented: $_isImportingPresenting) {



				FileImporterRepresentableView(



					allowedContentTypes:  [.ipa, .tipa],



					allowsMultipleSelection: true,



					onDocumentsPicked: { urls in



						guard !urls.isEmpty else { return }







						for url in urls {



							let downloadUUID = UUID().uuidString
						let id = "FeatherManualDownload_" + downloadUUID



							let dl = downloadManager.startArchive(from: url, id: id)



							try? downloadManager.handlePachageFile(url: url, dl: dl)



						}



					}



				)



				.ignoresSafeArea()



			}



			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {



				TextField(.localized("URL"), text: $_alertDownloadString)



					.textInputAutocapitalization(.never)



				Button(.localized("Cancel"), role: .cancel) {



					_alertDownloadString = ""



				}



				Button(.localized("OK")) {



					if let url = URL(string: _alertDownloadString) {



						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\\(UUID().uuidString)")



					}



				}



			}



			.task {



				_updateRepositoryUpdates()



		}



		.onReceive(sourcesViewModel.$sources) { _ in



			_updateRepositoryUpdates()



		}



		.onChange(of: _signedApps.map { $0.uuid }) { _ in



			_updateRepositoryUpdates()



		}



		.onChange(of: _importedApps.map { $0.uuid }) { _ in



			_updateRepositoryUpdates()



		}



		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in



				if let latest = _signedApps.first {



					_selectedInstallAppPresenting = AnyApp(base: latest)



				}



				}



			.onChange(of: _editMode) { mode in



				if mode == .inactive {



					_selectedAppUUIDs.removeAll()



				}



			}



		}



	}



}







}

// MARK: - Extension: View



extension LibraryView {

	@ViewBuilder
	private var librarySearchScopes: some View {
		ForEach(Scope.allCases, id: \.displayName) { scope in
			Text(scope.displayName)
				.tag(scope)
		}
	}




	private func _updateRepositoryUpdates() {
		let savedSourceURLs = Set(
			Storage.shared.getSources().compactMap {
				$0.sourceURL?.absoluteString
			}
		)

		var activeRepositories = Array(sourcesViewModel.sources.values)

		activeRepositories.removeAll { repository in
			!sourcesViewModel.sources.contains { source, candidate in
				guard
					let url = source.sourceURL?.absoluteString,
					savedSourceURLs.contains(url)
				else {
					return false
				}

				return candidate.id == repository.id
			}
		}

		UpdateManager.shared.refresh(
			repositories: activeRepositories,
			signedApps: Array(_signedApps),
			importedApps: Array(_importedApps)
		)
	}







	@ViewBuilder



	private func _importActions() -> some View {



		Button(.localized("Import from Files"), systemImage: "folder") {



			_isImportingPresenting = true



		}



		Button(.localized("Import from URL"), systemImage: "globe") {



			_isDownloadingPresenting = true



		}



	}



}







// MARK: - Extension: Bulk Delete



extension LibraryView {



	private func _bulkDeleteSelectedApps() {



		let selectedApps = _getAllApps().filter { app in



			guard let uuid = app.uuid else { return false }



			return _selectedAppUUIDs.contains(uuid)



		}







		for app in selectedApps {



			Storage.shared.deleteApp(for: app)



		}







		_selectedAppUUIDs.removeAll()







		// _editMode = .inactive



	}







	private func _getAllApps() -> [AppInfoPresentable] {



		var allApps: [AppInfoPresentable] = []







		if _selectedScope == .all || _selectedScope == .signed {



			allApps.append(contentsOf: _filteredSignedApps)



		}







		if _selectedScope == .all || _selectedScope == .imported {



			allApps.append(contentsOf: _filteredImportedApps)



		}







		return allApps



	}



}







// MARK: - Extension: View (Sort)



extension LibraryView {



	enum Scope: CaseIterable {



		case all



		case signed



		case imported







		var displayName: String {



			switch self {



			case .all: return .localized("All")



			case .signed: return .localized("Signed")



			case .imported: return .localized("Imported")



			}



		}



	}



}











// MARK: - Repository Updates UI







private struct ZagUpdatesHeader: View {
	let count: Int

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let phase = context.date.timeIntervalSinceReferenceDate
			let wave = (sin(phase * .pi * 1.25) + 1.0) / 2.0
			let opacity = 0.25 + (wave * 0.75)
			let scale = 0.78 + (wave * 0.22)

			HStack(spacing: 8) {
				Circle()
					.fill(Color.green)
					.frame(width: 9, height: 9)
					.opacity(opacity)
					.scaleEffect(scale)
					.shadow(
						color: Color.green.opacity(wave * 0.65),
						radius: 4
					)

				Text(.localized("Updates Available"))

				ZagUpdateBadge(count: count)

				Spacer(minLength: 0)
			}
		}
	}
}

private struct ZagUpdateRow: View {
	let update: UpdateManager.AvailableUpdate
	let onPreparedForInstall: (String) -> Void

	@ObservedObject private var transactionManager =
		ZagUpdateTransactionManager.shared

	var body: some View {
		HStack(spacing: 12) {
			appIcon

			VStack(alignment: .leading, spacing: 4) {
				Text(update.app.currentName)
					.font(.headline)

				Text("\(update.installedVersion) → \(update.availableVersion)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Spacer()

			zagUpdateButton
		}
	}

	@ViewBuilder
	private var zagUpdateButton: some View {
		let stage = transactionManager.stage(for: update)

		Button {
			transactionManager.prepare(update) { result in
				switch result {
				case .success(let signedUUID):
					onPreparedForInstall(signedUUID)

				case .failure(let error):
					UIAlertController.showAlertWithOk(
						title: .localized("Update Failed"),
						message: error.localizedDescription
					)
				}
			}
		} label: {
			HStack(spacing: 6) {
				if stage == .downloading ||
					stage == .importing ||
					stage == .signing
				{
					ProgressView()
						.controlSize(.small)
				}

				Text(stage?.title ?? .localized("Update"))
					.lineLimit(1)
					.font(.headline.bold())
			}
			.foregroundStyle(Color.accentColor)
			.padding(.horizontal, 18)
			.padding(.vertical, 6)
			.background(
				Color(
					red: 28.0 / 255.0,
					green: 28.0 / 255.0,
					blue: 30.0 / 255.0
				)
			)
			.clipShape(Capsule())
		}
		.buttonStyle(.borderless)
		.disabled(
			stage == .downloading ||
			stage == .importing ||
			stage == .signing ||
			stage == .readyToInstall
		)
	}

	@ViewBuilder
	private var appIcon: some View {
		LazyImage(url: update.app.iconURL) { state in
			if let image = state.image {
				image
					.resizable()
					.aspectRatio(contentMode: .fill)
			} else {
				Image(systemName: "app.fill")
					.resizable()
					.scaledToFit()
					.padding(10)
					.foregroundStyle(.secondary)
					.background(
						Color(uiColor: .secondarySystemBackground)
					)
			}
		}
		.frame(width: 48, height: 48)
		.clipShape(
			RoundedRectangle(
				cornerRadius: 11,
				style: .continuous
			)
		)
	}
}


private struct ZagUpdatesSection: View {
	let updates: [UpdateManager.AvailableUpdate]
	let onPreparedForInstall: (String) -> Void

	var body: some View {
		Section {
			ForEach(updates) { update in
				ZagUpdateRow(
					update: update,
					onPreparedForInstall: onPreparedForInstall
				)
			}
		} header: {
			ZagUpdatesHeader(
				count: updates.count
			)
		}
	}
}


private struct ZagLibraryHeader: View {



	let title: String



	let count: Int







	var body: some View {



		ZagSectionHeader(



			title: title,



			count: count



		)



	}



}







private struct FeatherCountBadge: View {



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







#if DEBUG







#Preview("Zag Store — Library") {



	LibraryView()



}







#endif



// MARK: - Search Dictation Compatibility



private struct ZagSearchDictationModifier: ViewModifier {

	@ViewBuilder

	func body(content: Content) -> some View {

		if #available(iOS 17.0, *) {

			content

				.searchDictationBehavior(

					.inline(activation: .onSelect)

				)

		} else {

			content

		}

	}

}



private extension View {

	func zagSearchDictation() -> some View {

		modifier(

			ZagSearchDictationModifier()

		)

	}

}

// MARK: - Zag Store Transactional Updates

@MainActor
final class ZagUpdateTransactionManager: ObservableObject {
	static let shared = ZagUpdateTransactionManager()

	enum Stage: Equatable {
		case downloading
		case importing
		case signing
		case readyToInstall
		case failed(String)

		var title: String {
			switch self {
			case .downloading:
				return "Downloading"
			case .importing:
				return "Importing"
			case .signing:
				return "Signing"
			case .readyToInstall:
				return "Install"
			case .failed:
				return "Retry"
			}
		}
	}

	@Published private(set) var stages: [String: Stage] = [:]

	private init() {}

	func stage(for update: UpdateManager.AvailableUpdate) -> Stage? {
		stages[update.id]
	}

	func prepare(
		_ update: UpdateManager.AvailableUpdate,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		guard stages[update.id] == nil || isRetryable(update) else {
			return
		}

		guard let downloadURL = update.app.currentDownloadUrl else {
			let error = ZagUpdateTransactionError.missingDownloadURL
			stages[update.id] = .failed(error.localizedDescription)
			completion(.failure(error))
			return
		}

		stages[update.id] = .downloading

		Task {
			var downloadedFile: URL?

			do {
				let (temporaryURL, _) = try await URLSession.shared.download(from: downloadURL)

				let localURL = FileManager.default.temporaryDirectory
					.appendingPathComponent("ZagUpdate_\(UUID().uuidString).ipa")

				try? FileManager.default.removeItem(at: localURL)
				try FileManager.default.moveItem(at: temporaryURL, to: localURL)
				downloadedFile = localURL

				stages[update.id] = .importing

				let importHandler = AppFileHandler(file: localURL)

				try await importHandler.copy()
				try await importHandler.extract()
				try await importHandler.move()
				try await importHandler.addToDatabase()
				try? await importHandler.clean()

				guard let imported = importedApp(uuid: importHandler.uuid) else {
					throw ZagUpdateTransactionError.importedRecordNotFound
				}

				stages[update.id] = .signing

				let certificateIndex = UserDefaults.standard.integer(
					forKey: "feather.selectedCert"
				)

				guard let certificate = Storage.shared.getCertificate(
					for: certificateIndex
				) else {
					throw ZagUpdateTransactionError.missingCertificate
				}

				var options = OptionsManager.shared.options

				if
					options.ppqProtection,
					let identifier = imported.identifier,
					certificate.ppQCheck
				{
					options.appIdentifier =
						"\(identifier).\(OptionsManager.shared.options.ppqString)"
				}

				if
					let identifier = imported.identifier,
					let mappedIdentifier = options.identifiers[identifier]
				{
					options.appIdentifier = mappedIdentifier
				}

				if
					let name = imported.name,
					let mappedName = options.displayNames[name]
				{
					options.appName = mappedName
				}

				let signingHandler = SigningHandler(
					app: imported,
					options: options
				)

				signingHandler.appCertificate = certificate

				try await signingHandler.copy()
				try await signingHandler.modify()
				try? await signingHandler.clean()

				guard signedApp(uuid: signingHandler.uuid) != nil else {
					throw ZagUpdateTransactionError.signedRecordNotFound
				}

				try? FileManager.default.removeItem(at: localURL)

				stages[update.id] = .readyToInstall
				completion(.success(signingHandler.uuid))
			} catch {
				if let downloadedFile {
					try? FileManager.default.removeItem(at: downloadedFile)
				}

				stages[update.id] = .failed(error.localizedDescription)
				completion(.failure(error))
			}
		}
	}

	func reset(_ update: UpdateManager.AvailableUpdate) {
		stages[update.id] = nil
	}

	private func isRetryable(_ update: UpdateManager.AvailableUpdate) -> Bool {
		if case .failed = stages[update.id] {
			return true
		}

		return false
	}

	private func importedApp(uuid: String) -> Imported? {
		let request = Imported.fetchRequest()
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)

		return try? Storage.shared.context.fetch(request).first
	}

	func signedApp(uuid: String) -> Signed? {
		let request = Signed.fetchRequest()
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)

		return try? Storage.shared.context.fetch(request).first
	}
}

private enum ZagUpdateTransactionError: LocalizedError {
	case missingDownloadURL
	case missingCertificate
	case importedRecordNotFound
	case signedRecordNotFound

	var errorDescription: String? {
		switch self {
		case .missingDownloadURL:
			return "The repository did not provide a download URL."
		case .missingCertificate:
			return "No signing certificate is selected."
		case .importedRecordNotFound:
			return "The imported update could not be found."
		case .signedRecordNotFound:
			return "The signed update could not be found."
		}
	}
}

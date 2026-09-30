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
	@State private var _isUpdatesPresenting = false



	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting







	// MARK: Selection State



	@State private var _selectedAppUUIDs: Set<String> = []



	@State private var _editMode: EditMode = .inactive







	@State private var _searchText = ""

	@State private var _dictationAvailable = false
	@FocusState private var _searchFieldFocused: Bool



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
			Button {
				_isUpdatesPresenting = true
			} label: {
				ZStack {
					ZagUpdatesPillSurface()

					HStack(alignment: .center, spacing: 10) {
						Image(systemName: "arrow.triangle.2.circlepath")
							.font(.system(size: 21, weight: .regular))
							.foregroundStyle(.primary)
							.frame(width: 24, height: 24)

						Text(.localized("App Updates"))
							.font(.system(size: 20, weight: .semibold))
							.foregroundStyle(.primary)

						ZagFlashingUpdateDot()
							.frame(width: 9, height: 9)

						Spacer(minLength: 8)

						Text(updateManager.updates.count.description)
							.font(.system(size: 14, weight: .regular))
							.foregroundStyle(.white)
							.frame(width: 24, height: 24)
							.background(
								Circle()
									.fill(Color(hex: "#E93323"))
							)
					}
					.padding(.horizontal, 16)
				}
				.frame(height: 50)
				.padding(.top, -20)
				.contentShape(Capsule())
			}
			.buttonStyle(.plain)
			.listRowSeparator(.hidden)
			.padding(.vertical, 2)
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

	var body: some View {



		NBNavigationView(.localized("Apps")) {



			NBListAdaptable {



			zagUpdatesContent

				if



					!_filteredSignedApps.isEmpty,



					_selectedScope == .all || _selectedScope == .signed



				{



					Section {

						ZagLibraryHeader(
							title: .localized("Signed"),
							count: _filteredSignedApps.count
						)
						.listRowSeparator(.hidden)



						ForEach(_filteredSignedApps, id: \.uuid) { app in



							LibraryCellView(



								app: app,



								selectedInfoAppPresenting: $_selectedInfoAppPresenting,



								selectedSigningAppPresenting: $_selectedSigningAppPresenting,



								selectedInstallAppPresenting: $_selectedInstallAppPresenting,



								selectedAppUUIDs: $_selectedAppUUIDs



							)



							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)



						}



					}



				}







				if



					!_filteredImportedApps.isEmpty,



					_selectedScope == .all || _selectedScope == .imported



				{



					Section {

						ZagLibraryHeader(
							title: .localized("Imported"),
							count: _filteredImportedApps.count
						)
						.listRowSeparator(.hidden)



						ForEach(_filteredImportedApps, id: \.uuid) { app in



							LibraryCellView(



								app: app,



								selectedInfoAppPresenting: $_selectedInfoAppPresenting,



								selectedSigningAppPresenting: $_selectedSigningAppPresenting,



								selectedInstallAppPresenting: $_selectedInstallAppPresenting,



								selectedAppUUIDs: $_selectedAppUUIDs



							)



							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)



						}



					}



				}



			}
			.toolbarBackground(.hidden, for: .navigationBar)
			.searchable(
				text: $_searchText,
				placement: .platform(),
				prompt: Text("Apps, Games and More")
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
					prompt: "Apps, Games and More",
					activePrompt: "Apps, Games and More"
				)
				.frame(width: 0, height: 0)
			}



			.onAppear {
				_probeSystemDictation()
			}

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
					Button {
						withAnimation {
							_editMode = _editMode.isEditing ? .inactive : .active
						}
					} label: {
						Image(systemName: "square.and.pencil")
							.font(.system(size: 20, weight: .semibold))
					}
					.accessibilityLabel(
						_editMode.isEditing
							? Text(.localized("Done"))
							: Text(.localized("Edit"))
					)
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

			.sheet(isPresented: $_isUpdatesPresenting) {
				ZagUpdatesPopup(
					updates: updateManager.updates,
					onPreparedForInstall: { signedUUID in
						_isUpdatesPresenting = false
						handlePreparedUpdate(signedUUID)
					}
				)
			}

			.sheet(item: $_selectedInfoAppPresenting) { app in



				LibraryInfoView(app: app.base)



			}



			.sheet(item: $_selectedInstallAppPresenting) { app in



				InstallPreviewView(
					app: app.base,
					isSharing: app.archive,
					onInstallCompleted: {
						guard let signedUUID = app.base.uuid else { return }
						ZagUpdateTransactionManager.shared.completeInstallation(
							signedUUID: signedUUID
						)
					}
				)



					.presentationDetents([.height(200)])



					.presentationDragIndicator(.visible)



			}



			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in



				SigningView(app: app.base)



					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)



			}



			.sheet(isPresented: $_isImportingPresenting) {



				FileImporterRepresentableView(



					allowedContentTypes: [.ipa, .tipa],



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



						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")



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







private struct ZagUpdatesPillSurface: View {
	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#3F8EF7"

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let cycle = context.date.timeIntervalSinceReferenceDate
				.truncatingRemainder(dividingBy: 5.2)
			let progress = min(max((cycle - 4.0) / 1.2, 0), 1)
			let travelling = progress > 0 && progress < 1

			Capsule()
				.fill(Color(hex: "#2C2C2E"))
				.overlay {
					Capsule()
						.trim(from: max(0, progress - 0.10), to: min(1, progress + 0.10))
						.stroke(
							Color(hex: themeColorHex)
								.opacity(travelling ? 0.34 : 0),
							style: StrokeStyle(
								lineWidth: 0.75,
								lineCap: .round
							)
						)
						.animation(.easeInOut(duration: 0.18), value: travelling)
				}
		}
	}
}


private struct ZagFlashingUpdateDot: View {
	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let phase = context.date.timeIntervalSinceReferenceDate
			let wave = (sin(phase * .pi * 1.25) + 1.0) / 2.0

			Circle()
				.fill(Color.green)
				.frame(width: 9, height: 9)
				.opacity(0.25 + (wave * 0.75))
				.scaleEffect(0.78 + (wave * 0.22))
				.shadow(
					color: Color.green.opacity(wave * 0.65),
					radius: 4
				)
		}
	}
}


private struct ZagUpdateRow: View {
	let update: UpdateManager.AvailableUpdate
	@Environment(\.colorScheme) private var colorScheme

	@AppStorage("Feather.userTintColor")
	private var selectedColorHex: String = "#4395F8"

	@AppStorage("Feather.shouldTintIcons")
	private var shouldTintIcons: Bool = false

	@AppStorage("Feather.shouldChangeIconsBasedOffStyle")
	private var shouldChangeIconsBasedOffStyle: Bool = false

	private var useDarkIconAppearance: Bool {
		shouldChangeIconsBasedOffStyle &&
		colorScheme == .dark
	}
	let onPreparedForInstall: (String) -> Void

	@ObservedObject private var transactionManager =
		ZagUpdateTransactionManager.shared

	var body: some View {
		HStack(spacing: 10) {
			appIcon

			VStack(alignment: .leading, spacing: 4) {
				Text(update.app.currentName)
					.zagContentTitleStyle()

				Text("\(update.installedVersion) → \(update.availableVersion)")
					.zagContentSubtitleStyle()
			}

			Spacer()

			zagUpdateButton
		}
		.zagAppStoreRowSeparator()
	}

	@ViewBuilder
	private var zagUpdateButton: some View {
		let stage = transactionManager.stage(for: update)
		let isBusy =
			stage == .downloading ||
			stage == .importing ||
			stage == .signing

		ZagActionPill(
			title: stage?.title ?? .localized("Update"),
			showsProgress: isBusy
		) {
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
		}
		.disabled(
			isBusy ||
			stage == .readyToInstall
		)
	}

	@ViewBuilder
	private var appIcon: some View {
		LazyImage(url: update.app.iconURL) { state in
			if let image = state.image {
				if shouldTintIcons {
					image
			.resizable()
			.aspectRatio(contentMode: .fill)
			.saturation(0)
			.contrast(1.25)
			.overlay(
				Color(hex: selectedColorHex)
					.opacity(0.82)
					.blendMode(.color)
			)
			} else if useDarkIconAppearance {
					image
						.resizable()
						.aspectRatio(contentMode: .fill)
						.brightness(-0.18)
						.contrast(1.08)
				} else {
					image
						.resizable()
						.aspectRatio(contentMode: .fill)
				}
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
		.frame(width: 62, height: 62)
		.clipShape(
			RoundedRectangle(
				cornerRadius: 11,
				style: .continuous
			)
		)
	}
}


private struct ZagUpdatesPopup: View {
	let updates: [UpdateManager.AvailableUpdate]
	let onPreparedForInstall: (String) -> Void

	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			List {
				ForEach(updates) { update in
					ZagUpdateRow(
						update: update,
						onPreparedForInstall: onPreparedForInstall
					)
				}
			}
			.listStyle(.plain)
			.listRowSeparator(.hidden)
			.navigationTitle(.localized("App Updates"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						dismiss()
					} label: {
						Image(systemName: "xmark")
							.font(.system(size: 13, weight: .bold))
					}
					.buttonStyle(.bordered)
					.clipShape(Circle())
				}
			}
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

	private struct PendingUpdate {
		let updateID: String
		let importedUUID: String
		let signedUUID: String
		let supersededSignedUUIDs: [String]
	}

	private var pendingBySignedUUID: [String: PendingUpdate] = [:]

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

				guard let newSigned = signedApp(uuid: signingHandler.uuid) else {
					throw ZagUpdateTransactionError.signedRecordNotFound
				}

				let supersededSignedUUIDs = signedApps(
					matchingIdentifier: newSigned.identifier,
					name: newSigned.name,
					version: update.installedVersion,
					excludingUUID: signingHandler.uuid
				).compactMap(\.uuid)

				pendingBySignedUUID[signingHandler.uuid] = PendingUpdate(
					updateID: update.id,
					importedUUID: importHandler.uuid,
					signedUUID: signingHandler.uuid,
					supersededSignedUUIDs: supersededSignedUUIDs
				)

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

	func completeInstallation(signedUUID: String) {
		guard let pending = pendingBySignedUUID.removeValue(forKey: signedUUID) else {
			return
		}

		if let imported = importedApp(uuid: pending.importedUUID) {
			Storage.shared.deleteApp(for: imported)
		}

		for oldUUID in pending.supersededSignedUUIDs {
			guard oldUUID != pending.signedUUID else { continue }
			if let oldSigned = signedApp(uuid: oldUUID) {
				Storage.shared.deleteApp(for: oldSigned)
			}
		}

		stages[pending.updateID] = nil
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

	private func signedApps(
		matchingIdentifier identifier: String?,
		name: String?,
		version: String,
		excludingUUID: String
	) -> [Signed] {
		guard let identifier, let name else { return [] }

		let request = Signed.fetchRequest()
		request.predicate = NSPredicate(
			format: "identifier == %@ AND version == %@ AND uuid != %@",
			identifier,
			version,
			excludingUUID
		)

		let normalizedName = normalizeAppName(name)

		return (try? Storage.shared.context.fetch(request))?.filter {
			guard let candidateName = $0.name else { return false }
			return normalizeAppName(candidateName) == normalizedName
		} ?? []
	}

	private func normalizeAppName(_ value: String) -> String {
		value
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.joined()
			.lowercased()
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

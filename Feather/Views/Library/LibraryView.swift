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

	@Environment(\.scenePhase) private var scenePhase



	@StateObject var downloadManager = DownloadManager.shared



	@StateObject private var sourcesViewModel = SourcesViewModel.shared
	@State private var selectedUpdate: UpdateManager.AvailableUpdate?



	@StateObject private var updateManager = UpdateManager.shared
	@StateObject private var rppairingCore = ZagRPPairingCore.shared










	@State private var _selectedInfoAppPresenting: AnyApp?



	@State private var _selectedSigningAppPresenting: AnyApp?



	@State private var _selectedInstallAppPresenting: AnyApp?



	@State private var _isImportingPresenting = false



	@State private var _isDownloadingPresenting = false
	@State private var _isUpdatesPresenting = false
	@State private var _removingBundleIDs: Set<String> = []
	@AppStorage("zagStore.managedInstalledBundleIDs")
	private var _managedInstalledBundleIDsData: Data = Data()



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

	private var _filteredInstalledApps: [Signed] {
		_filteredSignedApps.filter { app in
			guard let identifier = app.identifier, !identifier.isEmpty else {
				return false
			}
			return _managedInstalledBundleIDs.contains(identifier)
		}
	}

	private var _filteredSignedOnlyApps: [Signed] {
		_filteredSignedApps.filter { app in
			guard let identifier = app.identifier, !identifier.isEmpty else {
				return true
			}
			return !_managedInstalledBundleIDs.contains(identifier)
		}
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



	@Environment(\.colorScheme) private var zagUpdatesColorScheme
	@AppStorage("Feather.userTintColor") private var zagUpdatesThemeHex: String = "#3F8EF7"

	private var zagUpdatesPillBackground: Color {
		zagUpdatesColorScheme == .dark
			? Color(hex: "#1C1C1E")
			: Color(hex: "#EEEEEF")
	}

	private var zagUpdatesTitleColor: Color {
		Color(hex: zagUpdatesThemeHex)
	}

	@ViewBuilder
	private var zagUpdatesContent: some View {
		if updateManager.hasVisibleUpdates {
			Button {
				_isUpdatesPresenting = true
			} label: {
				HStack(spacing: 12) {
					HStack(spacing: 9) {
						Text(.localized("Updates"))
							.font(.system(size: 20, weight: .semibold))
							.foregroundStyle(zagUpdatesTitleColor)

						ZagFlashingUpdateDot()
							.frame(width: 9, height: 9)
							.offset(y: 1)
					}
					.padding(.horizontal, 14)
					.frame(height: 46)
					.background(zagUpdatesPillBackground)
					.clipShape(Capsule())

					ZagUpdateTransferParticles()
						.frame(maxWidth: .infinity)

					ZStack {
						ZagUpdatesPillSurface(
							baseColorHex: zagUpdatesColorScheme == .dark
								? "#1C1C1E"
								: "#EEEEEF"
						)

						Text(updateManager.updateCount.description)
							.font(.system(size: 14, weight: .regular))
							.foregroundStyle(.white)
							.frame(width: 24, height: 24)
							.background(
								Circle()
									.fill(Color(hex: "#E93323"))
							)
					}
					.frame(width: 54, height: 46)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				// Native search scopes consume additional vertical space while
				// search is active. Do not pull the animated Updates row into them.
				.padding(.top, _searchFieldFocused ? 0 : -16)
			}
			.buttonStyle(.plain)
			.listRowSeparator(.hidden)
			.listRowBackground(Color.clear)
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



			NBListAdaptable(transparentBackground: true) {
				Group {



			zagUpdatesContent

				if
					!_filteredInstalledApps.isEmpty,
					_selectedScope == .all || _selectedScope == .installed
				{
					Section {
						ZagLibraryHeader(
							title: .localized("Installed"),
							count: _filteredInstalledApps.count
						)
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)

						ForEach(_filteredInstalledApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								isManagedInstalled: true,
								isRemoving: _removingBundleIDs.contains(app.identifier ?? ""),
								onDeleteApp: _deleteStoredApp,
								onRemoveManagedApp: _removeManagedApp,
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
					!_filteredSignedOnlyApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					Section {

						ZagLibraryHeader(
							title: .localized("Signed"),
							count: _filteredSignedOnlyApps.count
						)
						.listRowSeparator(.hidden)
			.listRowBackground(Color.clear)



						ForEach(_filteredSignedOnlyApps, id: \.uuid) { app in



							LibraryCellView(



								app: app,
								isManagedInstalled: _managedInstalledBundleIDs.contains(app.identifier ?? ""),
								isRemoving: _removingBundleIDs.contains(app.identifier ?? ""),
								onDeleteApp: _deleteStoredApp,
								onRemoveManagedApp: _removeManagedApp,



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
			.listRowBackground(Color.clear)



						ForEach(_filteredImportedApps, id: \.uuid) { app in



							LibraryCellView(



								app: app,
								isManagedInstalled: _managedInstalledBundleIDs.contains(app.identifier ?? ""),
								isRemoving: _removingBundleIDs.contains(app.identifier ?? ""),
								onDeleteApp: _deleteStoredApp,
								onRemoveManagedApp: _removeManagedApp,



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
				.listRowBackground(Color.clear)
			}
			.zagWallpaperSurface()
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



								ZagActionPill(title: .localized("Import")) {
									_isImportingPresenting = true
								}



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
			.onChange(of: scenePhase) { phase in
				guard phase == .active else { return }
				_refreshInstalledAppsFromDevice()
			}
			.onAppear {
				_refreshInstalledAppsFromDevice()
			}

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
						// Preserve the immediate UI response for every installer, then
						// let device inventory confirm the authoritative state.
						_markManagedAppInstalled(app.base)
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
							_refreshInstalledAppsFromDevice()
						}

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



		.onChange(of: _signedApps.map { $0.uuid }) { _ in



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

	private var _managedInstalledBundleIDs: Set<String> {
		guard
			!_managedInstalledBundleIDsData.isEmpty,
			let identifiers = try? JSONDecoder().decode(
				Set<String>.self,
				from: _managedInstalledBundleIDsData
			)
		else {
			return []
		}
		return identifiers
	}

	private func _markManagedAppInstalled(_ app: AppInfoPresentable) {
		guard let identifier = app.identifier, !identifier.isEmpty else {
			return
		}

		var identifiers = _managedInstalledBundleIDs
		identifiers.insert(identifier)

		if let encoded = try? JSONEncoder().encode(identifiers) {
			_managedInstalledBundleIDsData = encoded
		}
	}

	private func _refreshInstalledAppsFromDevice() {
		guard rppairingCore.pairingFileExists else {
			_reconcileManagedInstalledApps()
			_updateRepositoryUpdates()
			return
		}

		do {
			try rppairingCore.refreshInstalledApps { result in
				DispatchQueue.main.async {
					switch result {
					case .success(let installedBundleIDs):
						if let encoded = try? JSONEncoder().encode(installedBundleIDs) {
							_managedInstalledBundleIDsData = encoded
						}
						_updateRepositoryUpdates()

					case .failure(let error):
						print(
							"[Zag Store Inventory] Device inventory refresh failed: " +
							error.localizedDescription
						)
						_updateRepositoryUpdates()
					}
				}
			}
		} catch {
			print(
				"[Zag Store Inventory] Device inventory could not start: " +
				error.localizedDescription
			)
			_updateRepositoryUpdates()
		}
	}

	private func _reconcileManagedInstalledApps() {
		let identifiers = _managedInstalledBundleIDs
		guard !identifiers.isEmpty else { return }

		// If LaunchServices cannot answer on this iOS build, preserve the
		// existing state. Only IDs explicitly reported missing are removed.
		let missing = identifiers.filter { identifier in
			UIApplication.isAppInstalled(with: identifier) == false
		}
		guard !missing.isEmpty else { return }

		var reconciled = identifiers
		reconciled.subtract(missing)
		if let encoded = try? JSONEncoder().encode(reconciled) {
			_managedInstalledBundleIDsData = encoded
		}
	}

	private func _clearManagedInstalledMarker(_ identifier: String) {
		var identifiers = _managedInstalledBundleIDs
		identifiers.remove(identifier)
		if let encoded = try? JSONEncoder().encode(identifiers) {
			_managedInstalledBundleIDsData = encoded
		}
	}

	private func _deleteStoredApp(_ app: AppInfoPresentable) {
		if let identifier = app.identifier, !identifier.isEmpty {
			_clearManagedInstalledMarker(identifier)
		}
		Storage.shared.deleteApp(for: app)
	}

	private func _removeManagedApp(_ app: AppInfoPresentable) {
		guard let identifier = app.identifier, !identifier.isEmpty else {
			return
		}
		guard !_removingBundleIDs.contains(identifier) else {
			return
		}

		_removingBundleIDs.insert(identifier)

		func finishDirectRemoval() {
			// installation_proxy success is authoritative for the operation.
			// Update the UI immediately, then reconcile against the device
			// inventory once SpringBoard/device services have published the change.
			_clearManagedInstalledMarker(identifier)
			_removingBundleIDs.remove(identifier)

			DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
				_refreshInstalledAppsFromDevice()
			}
		}

		func tryLaunchServicesFallback() {
			guard UIApplication.removeApp(with: identifier) else {
				_removingBundleIDs.remove(identifier)
				UIAlertController.showAlertWithOk(
					title: .localized("Remove App"),
					message: .localized("Zag Store could not remove this application.")
				)
				return
			}

			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				if UIApplication.isAppInstalled(with: identifier) == false {
					_clearManagedInstalledMarker(identifier)
					_removingBundleIDs.remove(identifier)
				} else {
					_removingBundleIDs.remove(identifier)
					UIAlertController.showAlertWithOk(
						title: .localized("Remove App"),
						message: .localized("The uninstall request was sent, but iOS still reports the app as installed.")
					)
				}
			}
		}

		do {
			try ZagRPPairingCore.shared.uninstallGate4App(
				bundleID: identifier,
				deviceIP: "10.7.0.1"
			) { result in
				switch result {
				case .success:
					finishDirectRemoval()
				case .failure:
					// Fully Local Server and other non-RPPairing setups retain the
					// existing LaunchServices uninstall path as a fallback.
					tryLaunchServicesFallback()
				}
			}
		} catch {
			tryLaunchServicesFallback()
		}
	}

	@ViewBuilder
	private var librarySearchScopes: some View {
		ForEach(Scope.allCases, id: \.displayName) { scope in
			Text(scope.displayName)
				.tag(scope)
		}
	}




	private func _updateRepositoryUpdates() {
		// Library's FetchedResults can change while repositories are still
		// refreshing during launch. Never let that transient lifecycle event
		// replace the last known-good Updates snapshot with an empty/partial one.
		guard
			!sourcesViewModel.isRefreshing,
			!UpdateManager.shared.isRepositoryRefreshInProgress
		else {
			print(
				"[Zag Store Updates] Library reconciliation deferred: " +
				"repository refresh transaction is in progress"
			)
			return
		}

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

		// With configured sources, only a complete repository snapshot is
		// authoritative. A partial cache must never clear valid update state.
		guard savedSourceURLs.isEmpty || activeRepositories.count == savedSourceURLs.count else {
			print(
				"[Zag Store Updates] Library reconciliation deferred: " +
				"repository snapshot is incomplete (" +
				"\(activeRepositories.count)/\(savedSourceURLs.count))"
			)
			return
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



			_deleteStoredApp(app)



		}







		_selectedAppUUIDs.removeAll()







		// _editMode = .inactive



	}







	private func _getAllApps() -> [AppInfoPresentable] {



		var allApps: [AppInfoPresentable] = []







		if _selectedScope == .all || _selectedScope == .installed {
			allApps.append(contentsOf: _filteredInstalledApps)
		}

		if _selectedScope == .all || _selectedScope == .signed {
			allApps.append(contentsOf: _filteredSignedOnlyApps)
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

		case installed

		case signed

		case imported







		var displayName: String {



			switch self {



			case .all: return .localized("All")

			case .installed: return .localized("Installed")

			case .signed: return .localized("Signed")



			case .imported: return .localized("Imported")



			}



		}



	}



}











// MARK: - Repository Updates UI







private struct ZagUpdateTransferParticles: View {
	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#3F8EF7"

	var body: some View {
		GeometryReader { proxy in
			TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
				let cycle = context.date.timeIntervalSinceReferenceDate
					.truncatingRemainder(dividingBy: 6.3)
				let width = max(proxy.size.width, 1)
				let grow = min(max((cycle - 0.42) / 0.48, 0), 1)
				let dissolve = min(max((cycle - 3.00) / 0.52, 0), 1)
				let filament = grow * (1 - dissolve)
				let launchFlare = exp(-pow((cycle - 0.92) / 0.13, 2))
				let impactFlare = exp(-pow((cycle - 2.62) / 0.15, 2))

				ZStack {
					// The electrical path is visible enough to connect both
					// controls, but remains subordinate to the moving energy.
					Capsule()
						.fill(Color(hex: themeColorHex))
						.frame(
							width: max(0, (width + 8) * grow),
							height: 1.0 / UIScreen.main.scale
						)
						.opacity(0.43 * filament)
						.shadow(
							color: Color(hex: themeColorHex).opacity(0.34 * filament),
							radius: 2.4
						)
						.frame(maxWidth: .infinity, alignment: .trailing)
						.offset(x: 4)

					// Launch flare lives just under the counter's left edge.
					ZStack {
						Circle()
							.fill(Color(hex: themeColorHex).opacity(0.42))
							.frame(width: 13, height: 13)
							.blur(radius: 4)
						Circle()
							.fill(Color.white)
							.frame(width: 3.5, height: 3.5)
					}
					.opacity(launchFlare)
					.offset(x: width / 2 + 2)

					// One dominant packet followed by two smaller echoes.
					ForEach(0..<3, id: \.self) { pulse in
						let launch = 0.92 + Double(pulse) * 0.28
						let duration = 1.70
						let local = min(max((cycle - launch) / duration, 0), 1)
						let eased = local * local * (3 - 2 * local)
						let visible = cycle >= launch && cycle <= launch + duration
						let strength = pulse == 0 ? 1.0 : (pulse == 1 ? 0.68 : 0.46)
						let tail = pulse == 0 ? 25.0 : (pulse == 1 ? 17.0 : 12.0)
						let core = pulse == 0 ? 13.0 : (pulse == 1 ? 9.0 : 6.5)

						ZStack {
							Capsule()
								.fill(Color(hex: themeColorHex).opacity(0.30 * strength))
								.frame(width: tail, height: pulse == 0 ? 4 : 3)
								.blur(radius: 2.4)

							Capsule()
								.fill(Color(hex: themeColorHex))
								.frame(width: core, height: pulse == 0 ? 1.8 : 1.3)

							Circle()
								.fill(Color.white)
								.frame(
									width: pulse == 0 ? 4.2 : 3.0,
									height: pulse == 0 ? 4.2 : 3.0
								)
						}
						.opacity(visible ? sin(local * .pi) * strength : 0)
						.offset(x: (width / 2 + 4) - CGFloat(eased) * (width + 8))
					}

					// Reception flare is tucked beneath the Updates capsule.
					ZStack {
						Circle()
							.fill(Color(hex: themeColorHex).opacity(0.52))
							.frame(width: 15, height: 15)
							.blur(radius: 4.5)
						Circle()
							.fill(Color.white)
							.frame(width: 4, height: 4)
					}
					.opacity(impactFlare)
					.offset(x: -width / 2 - 2)
				}
				.frame(width: proxy.size.width, height: proxy.size.height)
			}
		}
		.frame(height: 46)
	}
}


private struct ZagUpdatesPillSurface: View {
	var baseColorHex: String = "#2C2C2E"

	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#3F8EF7"

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let time = context.date.timeIntervalSinceReferenceDate
			let cycle = time.truncatingRemainder(dividingBy: 6.3)
			// Keep a slow ambient reflection, then concentrate light at the
			// counter's left edge immediately before the transmission launches.
			let progress = time.truncatingRemainder(dividingBy: 7.4) / 7.4
			let charge = exp(-pow((cycle - 0.82) / 0.28, 2))

			Capsule()
				.fill(Color(hex: baseColorHex))
				.overlay {
					ZStack {
						ZagUpdatesEdgeGlint(
							progress: progress,
							offset: -0.085,
							length: 0.27,
							color: Color(hex: themeColorHex),
							opacity: 0.20,
							lineWidth: 3.8
						)
						.blur(radius: 2.7)

						ZagUpdatesEdgeGlint(
							progress: progress,
							offset: -0.038,
							length: 0.15,
							color: Color(hex: themeColorHex),
							opacity: 0.40,
							lineWidth: 1.3
						)

						ZagUpdatesEdgeGlint(
							progress: progress,
							offset: 0,
							length: 0.024,
							color: .white,
							opacity: 0.92,
							lineWidth: 0.8
						)

						// Synchronized charge at the left side of the counter.
						Capsule()
							.trim(from: 0.43, to: 0.57)
							.stroke(
								Color(hex: themeColorHex).opacity(0.30 + charge * 0.55),
								style: StrokeStyle(lineWidth: 1.5 + charge * 0.9, lineCap: .round)
							)
							.blur(radius: charge * 1.6)

						Capsule()
							.trim(from: 0.485, to: 0.515)
							.stroke(
								Color.white.opacity(charge * 0.92),
								style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
							)
					}
					.mask {
						Capsule()
							.stroke(
								AngularGradient(
									colors: [
										.white.opacity(0.62),
										.white,
										.white.opacity(0.90),
										.white.opacity(0.42),
										.white.opacity(0.32),
										.white.opacity(0.58),
										.white.opacity(0.62)
									],
									center: .center
								),
								lineWidth: 7
							)
					}
					.clipShape(Capsule())
				}
		}
	}
}


private struct ZagUpdatesEdgeGlint: View {
	let progress: Double
	let offset: Double
	let length: Double
	let color: Color
	let opacity: Double
	let lineWidth: CGFloat

	var body: some View {
		let center = wrapped(progress + offset)
		let half = length / 2.0
		let start = center - half
		let end = center + half

		ZStack {
			if start >= 0 && end <= 1 {
				segment(from: start, to: end)
			} else if start < 0 {
				segment(from: 0, to: end)
					.overlay {
						segment(from: 1 + start, to: 1)
					}
			} else {
				segment(from: start, to: 1)
					.overlay {
						segment(from: 0, to: end - 1)
					}
			}
		}
	}

	private func wrapped(_ value: Double) -> Double {
		let remainder = value.truncatingRemainder(dividingBy: 1)
		return remainder >= 0 ? remainder : remainder + 1
	}

	private func segment(from: Double, to: Double) -> some View {
		Capsule()
			.trim(from: max(0, from), to: min(1, to))
			.stroke(
				color.opacity(opacity),
				style: StrokeStyle(
					lineWidth: lineWidth,
					lineCap: .round
				)
			)
	}
}


private struct ZagFlashingUpdateDot: View {
	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let time = context.date.timeIntervalSinceReferenceDate
			let ambient = (sin(time * .pi * 1.05) + 1.0) / 2.0
			let cycle = time.truncatingRemainder(dividingBy: 6.3)
			let receive = exp(-pow((cycle - 2.62) / 0.15, 2))
			let energy = min(1, ambient * 0.48 + receive)

			Circle()
				.fill(Color.green)
				.frame(width: 9, height: 9)
				.opacity(0.30 + (energy * 0.70))
				.scaleEffect(0.80 + (energy * 0.30))
				.shadow(
					color: Color.green.opacity(energy * 0.88),
					radius: 4.2 + receive * 3
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

	@State private var showsFullReleaseNotes = false

	private var useDarkIconAppearance: Bool {
		shouldChangeIconsBasedOffStyle &&
		colorScheme == .dark
	}

	private var zagUpdatesBlue: Color {
		colorScheme == .dark
			? Color(hex: "#3F8EF7")
			: Color(hex: "#3A85F8")
	}

	private var zagUpdatePillBackground: Color {
		colorScheme == .dark
			? Color(hex: "#3E3D42")
			: Color(hex: "#EEEEF0")
	}

	let onPreparedForInstall: (String) -> Void
	let onSelect: () -> Void

	@ObservedObject private var transactionManager =
		ZagUpdateTransactionManager.shared

	private var releaseDate: Date? {
		update.app.currentAppVersion?.date?.date ??
		update.app.currentDate?.date
	}

	private var releaseDateText: String? {
		guard let releaseDate else { return nil }

		let calendar = Calendar.current
		let today = calendar.startOfDay(for: Date())
		let releaseDay = calendar.startOfDay(for: releaseDate)
		let days = calendar.dateComponents(
			[.day],
			from: releaseDay,
			to: today
		).day ?? 0

		switch days {
		case 0:
			return .localized("Today")
		case 1:
			return .localized("Yesterday")
		case 2:
			return .localized("Two Days Ago")
		case 3:
			return .localized("Three Days Ago")
		default:
			let formatter = DateFormatter()
			formatter.locale = .current
			formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
			return formatter.string(from: releaseDate)
		}
	}

	private var releaseMetadataText: String? {
		var parts: [String] = []

		if let version = update.app.currentVersion {
			var versionText = String(format: .localized("Version %@"), version)
			if let build = update.app.currentAppVersion?.build,
			   !build.isEmpty,
			   build != version {
				versionText += " (\(build))"
			}
			parts.append(versionText)
		}

		if let size = update.app.size {
			parts.append(size.formattedByteCount)
		}

		return parts.isEmpty ? nil : parts.joined(separator: " • ")
	}

	private var releaseNotes: String? {
		let notes =
			update.app.currentAppVersion?.localizedDescription ??
			update.app.versionDescription ??
			update.app.localizedDescription

		guard
			let notes,
			!notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else {
			return nil
		}

		return notes
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .center, spacing: 12) {
				appIcon

				VStack(alignment: .leading, spacing: 2) {
					Text(update.app.currentName)
						.zagContentTitleStyle()
						.lineLimit(1)

					if let releaseDateText {
						Text(releaseDateText)
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
				}

				Spacer(minLength: 8)

				zagUpdateButton
			}

			if let releaseNotes {
				VStack(alignment: .leading, spacing: showsFullReleaseNotes ? 8 : 0) {
					ZStack(alignment: .bottomTrailing) {
						Text(releaseNotes)
							.font(.system(size: 17, weight: .regular))
							.foregroundStyle(.primary)
							.lineLimit(showsFullReleaseNotes ? nil : 2)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.trailing, showsFullReleaseNotes ? 0 : 42)

						Button(.localized(showsFullReleaseNotes ? "less" : "more")) {
							withAnimation(.easeInOut(duration: 0.2)) {
								showsFullReleaseNotes.toggle()
							}
						}
						.font(.system(size: 17, weight: .regular))
						.foregroundStyle(zagUpdatesBlue)
					}

					if showsFullReleaseNotes, let releaseMetadataText {
						Text(releaseMetadataText)
							.font(.system(size: 16, weight: .regular))
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.padding(.top, 14)
		.padding(.bottom, releaseNotes == nil ? 14 : 8)
		.contentShape(Rectangle())
		.onTapGesture {
			onSelect()
		}
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
			showsProgress: isBusy,
			backgroundColor: zagUpdatePillBackground
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
		ZStack(alignment: .bottomLeading) {
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
					cornerRadius: 62 * 0.2677,
					style: .continuous
				)
			)

			if let sourceIconURL = update.source.currentIconURL {
				LazyImage(url: sourceIconURL) { state in
					if let image = state.image {
						image
							.appIconStyle(
								size: 20,
								isCircle: true,
								background: Color(
									uiColor: .secondarySystemBackground
								)
							)
							.offset(x: 46, y: 4)
					}
				}
			}
		}
	}
}


private struct ZagUpdatesPopup: View {
	let updates: [UpdateManager.AvailableUpdate]
	let onPreparedForInstall: (String) -> Void

	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) private var colorScheme
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [
			NSSortDescriptor(
				keyPath: \AltSource.name,
				ascending: true
			)
		]
	) private var sources: FetchedResults<AltSource>
	@StateObject private var sourcesViewModel = SourcesViewModel.shared
	@State private var selectedUpdate: UpdateManager.AvailableUpdate?

	private var popupBackground: Color {
		colorScheme == .dark ? Color(hex: "#1C1C1E") : Color(hex: "#F2F1F6")
	}

	private var sectionBackground: Color {
		colorScheme == .dark ? Color(hex: "#2C2C2E") : Color(hex: "#FFFFFF")
	}

	private var separatorColor: Color {
		colorScheme == .dark ? Color(hex: "#403F44") : Color(hex: "#E7E7E9")
	}

	private var updatesBlue: Color {
		colorScheme == .dark ? Color(hex: "#3F8EF7") : Color(hex: "#3A85F8")
	}

	var body: some View {
		NavigationStack {
			ZStack {
				popupBackground
					.ignoresSafeArea()

				ScrollView {
					LazyVStack(alignment: .leading, spacing: 18) {
						updateAllCard
							.padding(.top, 22)

						Text(.localized("Available Updates"))
							.font(.headline)
							.foregroundStyle(.secondary)
							.textCase(nil)
							.padding(.leading, 16)
							.padding(.top, 6)
							.padding(.bottom, -8)

						VStack(spacing: 0) {
							ForEach(Array(updates.enumerated()), id: \.element.id) { index, update in
								ZagUpdateRow(
									update: update,
									onPreparedForInstall: onPreparedForInstall,
									onSelect: {
										selectedUpdate = update
									}
								)
								.padding(.horizontal, 16)
								.padding(.top, index == 0 ? 8 : 0)

								if index < updates.count - 1 {
									Rectangle()
										.fill(separatorColor)
										.frame(height: 3.0 / UIScreen.main.scale)
										.padding(.horizontal, 16)
								}
							}
						}
						.background(
							sectionBackground,
							in: RoundedRectangle(cornerRadius: 24, style: .continuous)
						)
					}
					.padding(.horizontal, 16)
					.padding(.top, 18)
					.padding(.bottom, 30)
				}
				.refreshable {
					await sourcesViewModel.fetchSources(
						sources,
						refresh: true
					)
				}
			}
			.navigationTitle(.localized("App Updates"))
			.navigationBarTitleDisplayMode(.inline)
			.navigationDestination(
				isPresented: Binding(
					get: { selectedUpdate != nil },
					set: { if !$0 { selectedUpdate = nil } }
				)
			) {
				if let update = selectedUpdate {
					SourceAppsDetailView(
						source: update.source,
						app: update.app
					)
				}
			}
			.interactiveDismissDisabled()
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						dismiss()
					} label: {
						Image(systemName: "xmark")
					}
					.accessibilityLabel("Close")
				}
			}
		}
	}

	private var updateAllCard: some View {
		HStack {
			Text(.localized("Update All"))
				.font(.system(size: 20, weight: .regular))
				.foregroundStyle(updatesBlue)

			Spacer()

			Text(updates.count.description)
				.font(.system(size: 14, weight: .regular))
				.foregroundStyle(.white)
				.frame(minWidth: 24, minHeight: 24)
				.padding(.horizontal, updates.count > 99 ? 4 : 0)
				.background(Color(hex: "#FF3B30"), in: Capsule())
		}
		.padding(.horizontal, 16)
		.frame(minHeight: 60)
		.background(
			sectionBackground,
			in: RoundedRectangle(cornerRadius: 24, style: .continuous)
		)
		.accessibilityElement(children: .combine)
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

	func prepareAsync(_ update: UpdateManager.AvailableUpdate) async throws -> String {
		try await withCheckedThrowingContinuation { continuation in
			prepare(update) { result in
				continuation.resume(with: result)
			}
		}
	}

	func installPreparedUpdate(signedUUID: String) async throws {
		guard let signed = signedApp(uuid: signedUUID) else {
			throw ZagUpdateTransactionError.signedRecordNotFound
		}

		let archiveHandler = ArchiveHandler(app: signed)
		try await archiveHandler.move()
		let packageURL = try await archiveHandler.archive()

		defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Task { @MainActor in
				do {
					try ZagRPPairingCore.shared.installGate4IPA(
						at: packageURL,
						deviceIP: "10.7.0.1",
						completion: { result in continuation.resume(with: result) }
					)
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}

		completeInstallation(signedUUID: signedUUID)
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

		// The signed update is now the authoritative local copy. Reconcile the
		// repository snapshot immediately so build-only updates disappear from
		// Apps/Updates without waiting for a source refresh or relaunch.
		UpdateManager.shared.refresh(
			repositories: Array(SourcesViewModel.shared.sources.values)
		)
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

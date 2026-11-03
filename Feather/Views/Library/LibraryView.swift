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
import AltSourceKit







// MARK: - View



// Cache the decoded managed-app identifier set for the current persisted data.
// SwiftUI can evaluate the Apps list several times during its first transition.
private final class ZagManagedInstalledIDsCache {
    private var lastData: Data?
    private var lastIDs: Set<String> = []

    func identifiers(for data: Data) -> Set<String> {
        if lastData != data {
            lastData = data
            lastIDs = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
        }
        return lastIDs
    }
}

private struct ZagLibraryListSnapshot {
    let managedIDs: Set<String>
    let signedApps: [Signed]
    let installed: [Signed]
    let signedOnly: [Signed]
    let imported: [Imported]
    let uniqueUpdates: [String: UpdateManager.AvailableUpdate]

    func availableUpdate(for app: Signed) -> UpdateManager.AvailableUpdate? {
        guard let id = app.identifier, !id.isEmpty else { return nil }
        return uniqueUpdates[id]
    }
}

struct LibraryView: View {
	private static var didPerformInitialDeviceInventory = false
	private static var didMeasureFirstListPreparation = false

	@Environment(\.scenePhase) private var scenePhase



	@StateObject var downloadManager = DownloadManager.shared



	// Read only by handlers (and passed to SourceAppsView, which observes it).
	// Observing it here re-rendered this view for every refreshed repository.
	private let sourcesViewModel = SourcesViewModel.shared
	@State private var selectedUpdate: UpdateManager.AvailableUpdate?
	@State private var _selectedRepositorySource: AltSource?



	@StateObject private var updateManager = UpdateManager.shared
    @StateObject private var selfUpdateCoordinator = ZagSelfUpdateCoordinator.shared
	@StateObject private var rppairingCore = ZagRPPairingCore.shared










	@State private var _selectedInfoAppPresenting: AnyApp?



	@State private var _selectedSigningAppPresenting: AnyApp?



	@State private var _selectedInstallAppPresenting: AnyApp?



	@State private var _isImportingPresenting = false



	@State private var _isDownloadingPresenting = false
	@State private var _isUpdatesPresenting = false
    @State private var _isSelfUpdatePresenting = false
	@State private var _removingBundleIDs: Set<String> = []
	@State private var _pendingRemoveApp: AnyApp?
	@State private var _transactionSignedUUIDs: Set<String> = []
	@AppStorage("zagStore.managedInstalledBundleIDs")
	private var _managedInstalledBundleIDsData: Data = Data()
	@State private var _managedIDsCache = ZagManagedInstalledIDsCache()
	@AppStorage("zagStore.apps.installedCollapsed") private var _installedCollapsed = false
	@AppStorage("zagStore.apps.signedCollapsed") private var _signedCollapsed = false
	@AppStorage("zagStore.apps.importedCollapsed") private var _importedCollapsed = false



	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting







	// MARK: Selection State



	@State private var _selectedAppUUIDs: Set<String> = []



	@State private var _editMode: EditMode = .inactive
    @AppStorage("zagStore.apps.sortOrder") private var _sortOrder = 0
    @State private var _showAppDiagnostics = false







	@State private var _searchText = ""

	@State private var _dictationAvailable = false
	@FocusState private var _searchFieldFocused: Bool



	@State private var _selectedScope: Scope = .all











	@Namespace private var _namespace







	// horror



	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
        let filtered = apps.filter {
            _searchText.isEmpty ||
            (($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)
        }
        switch _sortOrder {
        case 1, 2:
            return filtered.sorted {
                let lhs = ($0.value(forKey: "name") as? String) ?? ""
                let rhs = ($1.value(forKey: "name") as? String) ?? ""
                let order = lhs.localizedStandardCompare(rhs)
                return _sortOrder == 1 ? order == .orderedAscending : order == .orderedDescending
            }
        default: return filtered
        }
    }


    // Derive the three visible app sections once per body evaluation rather
    // than repeatedly filtering the same Core Data results for every header,
    // row separator and animation value during initial navigation.
    private var _listSnapshot: ZagLibraryListSnapshot {
        let shouldMeasure = !Self.didMeasureFirstListPreparation &&
            ZagPerformanceMonitor.shared.isEnabled
        let startedAt = shouldMeasure ? ZagPerformanceMonitor.now() : 0
        let managed = _managedInstalledBundleIDs
        let signed = filteredAndSortedApps(from: _signedApps).filter {
            $0.identifier != Bundle.main.bundleIdentifier
        }
        let installed = signed.filter { app in
            guard let id = app.identifier, !id.isEmpty else { return false }
            return managed.contains(id) &&
                !ZagUpdateTransactionManager.shared.isPendingInstallationSigned(uuid: app.uuid)
        }
        let signedOnly = signed.filter { app in
            if let uuid = app.uuid, _transactionSignedUUIDs.contains(uuid) { return false }
            if ZagUpdateTransactionManager.shared.isPendingInstallationSigned(uuid: app.uuid) {
                return true
            }
            guard let id = app.identifier, !id.isEmpty else { return true }
            return !managed.contains(id)
        }
        let imported = filteredAndSortedApps(from: _importedApps)
        var uniqueUpdates: [String: UpdateManager.AvailableUpdate] = [:]
        var ambiguous = Set<String>()
        for update in updateManager.updates {
            guard let id = update.app.id else { continue }
            if uniqueUpdates[id] == nil {
                uniqueUpdates[id] = update
            } else {
                ambiguous.insert(id)
            }
        }
        for id in ambiguous { uniqueUpdates.removeValue(forKey: id) }

        if shouldMeasure {
            Self.didMeasureFirstListPreparation = true
            let elapsed = ZagPerformanceMonitor.now() - startedAt
            let result = "signed=\(signed.count), imported=\(imported.count)"
            // A performance sample is Published state. Never publish it
            // synchronously while SwiftUI is evaluating a View body.
            DispatchQueue.main.async {
                ZagPerformanceMonitor.shared.record(
                    .appsListPreparation,
                    since: ZagPerformanceMonitor.now() - elapsed,
                    result: result
                )
            }
        }
        return ZagLibraryListSnapshot(
            managedIDs: managed,
            signedApps: signed,
            installed: installed,
            signedOnly: signedOnly,
            imported: imported,
            uniqueUpdates: uniqueUpdates
        )
    }

    // Keep device inventory intact; hide the store's own signed archive from Library.
    private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps).filter {
			$0.identifier != Bundle.main.bundleIdentifier
		}
	}

	private var _filteredInstalledApps: [Signed] {
		_filteredSignedApps.filter { app in
			guard let identifier = app.identifier, !identifier.isEmpty else {
				return false
			}
			return _managedInstalledBundleIDs.contains(identifier) &&
				!ZagUpdateTransactionManager.shared.isPendingInstallationSigned(uuid: app.uuid)
		}
	}

	// Never guess between variants that share a bundle identifier.
	// Only offer a row-level update when exactly one repository candidate matches.
	private func _installedRowUpdate(for app: Signed) -> UpdateManager.AvailableUpdate? {
		guard let identifier = app.identifier, !identifier.isEmpty else { return nil }
		let matches = updateManager.updates.filter { $0.app.id == identifier }
		return matches.count == 1 ? matches.first : nil
	}

	private var _filteredSignedOnlyApps: [Signed] {
		_filteredSignedApps.filter { app in
			if let uuid = app.uuid, _transactionSignedUUIDs.contains(uuid) {
				return false
			}

			if ZagUpdateTransactionManager.shared.isPendingInstallationSigned(uuid: app.uuid) {
				return true
			}
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
		ZagWideGamutTint.color(hex: zagUpdatesThemeHex)
	}

    // This announcement is exclusively for Zag Store itself.
    // Installed-app update counts live in the global avatar.
    @ViewBuilder
    private var zagUpdatesContent: some View {
        if let release = selfUpdateCoordinator.availableRelease {
            Button {
                _isSelfUpdatePresenting = true
            } label: {
                HStack(spacing: 4) {
                    HStack(spacing: 7) {
                        VStack(alignment: .center, spacing: 0) {
                            Text("Update")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color(uiColor: UIColor { traits in
                                    traits.userInterfaceStyle == .dark
                                        ? UIColor(white: 0.72, alpha: 1)
                                        : UIColor(white: 0.38, alpha: 1)
                                }))

                            // The release channel is the source of truth;
                            // this label follows Stable / Beta / Nightly.
                            Text(ZagSelfUpdateCoordinator.UpdateChannel.selected.rawValue.capitalized)
                                .font(.system(size: 10, weight: .medium))
                                .tracking(0.45)
                                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        ZagFlashingUpdateDot()
                            .frame(width: 9, height: 9)
                            .offset(y: 1)
                    }
                    // Match the native leading toolbar capsule on iPhone.
                    // Preserve the original 46pt height and rounded shape.
                    .frame(width: 112, height: 46)
                    .background(zagUpdatesPillBackground)
                    .clipShape(Capsule())

                    // Preserve the existing left-to-right energy flow,
                    // but use the extra width freed by the shorter pill.
                    // Version is centered above the line, never hardcoded.
                    ZagUpdateTransferParticles(
                        versionLabel: "\(release.version) (Build \(release.build))"
                    )
                    .frame(maxWidth: .infinity)

                    ZagUpdatesCore(
                        baseColorHex: zagUpdatesColorScheme == .dark ? "#1C1C1E" : "#EEEEEF"
                    )
                    .frame(width: 46, height: 46)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, _searchFieldFocused ? 0 : -16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Zag Store update available: \(release.version), Build \(release.build). Open Zag Store Update"
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .padding(.vertical, 2)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                )
            )
        }
    }

	private var _repositorySourceIsPresented: Binding<Bool> {
		Binding(
			get: { _selectedRepositorySource != nil },
			set: { if !$0 { _selectedRepositorySource = nil } }
		)
	}

	@ViewBuilder
	private var _repositoryDestination: some View {
		if let source = _selectedRepositorySource {
			SourceAppsView(
				object: [source],
				viewModel: sourcesViewModel
			)
		}
	}

	@ViewBuilder
	private var _updatesSheetContent: some View {
        ZagUpdatesPopup(updates: updateManager.updates)
    }

    private var _animatedUpdatesSheetBinding: Binding<Bool> {
        Binding(
            get: { _isUpdatesPresenting },
            set: { presented in
                _isUpdatesPresenting = presented
                NotificationCenter.default.post(
                    name: .zagUpdatesSheetVisibilityDidChange,
                    object: nil,
                    userInfo: ["presented": presented]
                )
            }
        )
    }

	@ViewBuilder
	private func _removeAppSheetContent(_ app: AnyApp) -> some View {
		VStack(spacing: 10) {
			Text(
				String(
					format: .localized("Remove “%@”?"),
					app.base.name ?? .localized("this app")
				)
			)
			.font(.system(size: 22, weight: .semibold))
			.multilineTextAlignment(.center)

			Text(.localized("This will uninstall the app from your iPhone. Its stored copy will remain in Zag Store so you can install it again later."))
				.font(.system(size: 17))
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)

			Spacer().frame(height: 10)

			Button {
				let target = app.base
				_pendingRemoveApp = nil
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
					_removeManagedApp(target)
				}
			} label: {
				Text(.localized("Delete App"))
					.font(.system(size: 20, weight: .semibold))
					.foregroundStyle(.red)
					.frame(maxWidth: .infinity)
					.frame(height: 52)
					.background(
						Color(uiColor: .tertiarySystemFill),
						in: RoundedRectangle(cornerRadius: 26, style: .continuous)
					)
			}
			.buttonStyle(.plain)

			Button {
				_pendingRemoveApp = nil
			} label: {
				Text(.localized("Cancel"))
					.font(.system(size: 20, weight: .semibold))
					.foregroundStyle(.primary)
					.frame(maxWidth: .infinity)
					.frame(height: 52)
					.background(
						Color(uiColor: .tertiarySystemFill),
						in: RoundedRectangle(cornerRadius: 26, style: .continuous)
					)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 20)
		.padding(.top, 24)
		.padding(.bottom, 8)
		.presentationDetents([.height(302)])
		.presentationDragIndicator(.visible)
	}

	@ViewBuilder
	private func _infoSheetContent(_ app: AnyApp) -> some View {
		LibraryInfoView(app: app.base)
	}

	@ViewBuilder
	private func _installSheetContent(_ app: AnyApp) -> some View {
		InstallPreviewView(
			app: app.base,
			isSharing: app.archive,
			onInstallCompleted: {
				_markManagedAppInstalled(app.base)
				_removeSupersededInstalledSignedCopies(keeping: app.base)
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

	@ViewBuilder
	private func _signingCoverContent(_ app: AnyApp) -> some View {
		SigningView(app: app.base)
			.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
	}

	@ViewBuilder
	private var _importSheetContent: some View {
		FileImporterRepresentableView(
			allowedContentTypes: [.ipa, .tipa],
			allowsMultipleSelection: true,
			onDocumentsPicked: _handleImportedDocuments
		)
		.ignoresSafeArea()
	}

	private func _handleImportedDocuments(_ urls: [URL]) {
		guard !urls.isEmpty else { return }

		for url in urls {
			let downloadUUID = UUID().uuidString
			let id = "FeatherManualDownload_" + downloadUUID
			let dl = downloadManager.startArchive(from: url, id: id)
			try? downloadManager.handlePachageFile(url: url, dl: dl)
		}
	}

	@ViewBuilder
	private var _downloadAlertActions: some View {
		TextField(.localized("URL"), text: $_alertDownloadString)
			.textInputAutocapitalization(.never)

		Button(.localized("Cancel"), role: .cancel) {
			_alertDownloadString = ""
		}

		Button(.localized("OK")) {
			_startAlertDownload()
		}
	}

	private func _startAlertDownload() {
		guard let url = URL(string: _alertDownloadString) else { return }
		_ = downloadManager.startDownload(
			from: url,
			id: "FeatherManualDownload_\(UUID().uuidString)"
		)
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



	@ViewBuilder
	private func libraryListContent(_ snapshot: ZagLibraryListSnapshot) -> some View {
		Group {
			zagUpdatesContent

			if !snapshot.installed.isEmpty,
			   _selectedScope == .all || _selectedScope == .installed {
				Section {
					ZagLibraryHeader(
						title: .localized("Installed"),
						count: snapshot.installed.count,
						isCollapsed: _installedCollapsed
					) {
						withAnimation(.easeInOut(duration: 0.28)) {
							_installedCollapsed.toggle()
						}
					}
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)

					if !_installedCollapsed {
					ForEach(Array(snapshot.installed.enumerated()), id: \.element.uuid) { index, app in
						LibraryCellView(
							app: app,
							isManagedInstalled: true,
							availableUpdate: snapshot.availableUpdate(for: app),
							isRemoving: _removingBundleIDs.contains(app.identifier ?? ""),
							showsSeparator: index < snapshot.installed.count - 1,
							onDeleteApp: _deleteStoredApp,
							onRemoveManagedApp: _requestRemoveManagedApp,
							onRepositoryBadgeTap: { source in _selectedRepositorySource = source },
							onSignedForInstall: _beginInstallTransaction,
							onInstallCompleted: _confirmInstalledApp,
							onInstallFailedAfterSigning: _failInstallTransaction,
							selectedInfoAppPresenting: $_selectedInfoAppPresenting,
							selectedSigningAppPresenting: $_selectedSigningAppPresenting,
							selectedInstallAppPresenting: $_selectedInstallAppPresenting,
							selectedAppUUIDs: $_selectedAppUUIDs
						)
						.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						.listRowSeparator(.hidden)
						.transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
					}
					}
				}
			}

			if !snapshot.signedOnly.isEmpty,
			   _selectedScope == .all || _selectedScope == .signed {
				Section {
					ZagLibraryHeader(
						title: .localized("Signed"),
						count: snapshot.signedOnly.count,
						isCollapsed: _signedCollapsed
					) {
						withAnimation(.easeInOut(duration: 0.28)) {
							_signedCollapsed.toggle()
						}
					}
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)

					if !_signedCollapsed {
					ForEach(Array(snapshot.signedOnly.enumerated()), id: \.element.uuid) { index, app in
						LibraryCellView(
							app: app,
							isManagedInstalled: snapshot.managedIDs.contains(app.identifier ?? ""),
							isRemoving: _removingBundleIDs.contains(app.identifier ?? ""),
							showsSeparator: index < snapshot.signedOnly.count - 1,
							onDeleteApp: _deleteStoredApp,
							onRemoveManagedApp: _requestRemoveManagedApp,
							onRepositoryBadgeTap: { source in _selectedRepositorySource = source },
							onSignedForInstall: _beginInstallTransaction,
							onInstallCompleted: _confirmInstalledApp,
							onInstallFailedAfterSigning: _failInstallTransaction,
							selectedInfoAppPresenting: $_selectedInfoAppPresenting,
							selectedSigningAppPresenting: $_selectedSigningAppPresenting,
							selectedInstallAppPresenting: $_selectedInstallAppPresenting,
							selectedAppUUIDs: $_selectedAppUUIDs
						)
						.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						.listRowSeparator(.hidden)
						.transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
					}
					}
				}
			}

			if !snapshot.imported.isEmpty,
			   _selectedScope == .all || _selectedScope == .imported {
				Section {
					ZagLibraryHeader(
						title: .localized("Imported"),
						count: snapshot.imported.count,
						isCollapsed: _importedCollapsed
					) {
						withAnimation(.easeInOut(duration: 0.28)) {
							_importedCollapsed.toggle()
						}
					}
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)

					if !_importedCollapsed {
					ForEach(Array(snapshot.imported.enumerated()), id: \.element.uuid) { index, app in
						LibraryCellView(
							app: app,
							isManagedInstalled: snapshot.managedIDs.contains(app.identifier ?? ""),
							isRemoving: _removingBundleIDs.contains(app.identifier ?? ""),
							showsSeparator: index < snapshot.imported.count - 1,
							onDeleteApp: _deleteStoredApp,
							onRemoveManagedApp: _requestRemoveManagedApp,
							onRepositoryBadgeTap: { source in _selectedRepositorySource = source },
							onSignedForInstall: _beginInstallTransaction,
							onInstallCompleted: _confirmInstalledApp,
							onInstallFailedAfterSigning: _failInstallTransaction,
							selectedInfoAppPresenting: $_selectedInfoAppPresenting,
							selectedSigningAppPresenting: $_selectedSigningAppPresenting,
							selectedInstallAppPresenting: $_selectedInstallAppPresenting,
							selectedAppUUIDs: $_selectedAppUUIDs
						)
						.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						.listRowSeparator(.hidden)
						.transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
					}
					}
				}
			}

			Color.clear
				.frame(height: 48)
				.listRowInsets(EdgeInsets())
				.listRowSeparator(.hidden)
				.listRowBackground(Color.clear)
		}
		.listRowBackground(Color.clear)
	}

	var body: some View {
		let snapshot = _listSnapshot

		NBNavigationView(.localized("Apps")) {



			NBListAdaptable(transparentBackground: true) {
				libraryListContent(snapshot)
			}
			.modifier(ZagLibrarySectionSpacingModifier())
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
			.animation(
				.easeInOut(duration: 0.35),
				value: updateManager.hasVisibleUpdates
			)
			.animation(
				.easeInOut(duration: 0.35),
				value: snapshot.installed.compactMap(\.uuid)
			)
			.animation(
				.easeInOut(duration: 0.35),
				value: snapshot.signedOnly.compactMap(\.uuid)
			)
			.animation(
				.easeInOut(duration: 0.35),
				value: snapshot.imported.compactMap(\.uuid)
			)
			.animation(
				.easeInOut(duration: 0.28),
				value: _installedCollapsed
			)
			.animation(
				.easeInOut(duration: 0.28),
				value: _signedCollapsed
			)
			.animation(
				.easeInOut(duration: 0.28),
				value: _importedCollapsed
			)

			.compatSearchScopes($_selectedScope) {
				librarySearchScopes
			}



			.scrollDismissesKeyboard(.interactively)



			.overlay {



				if



					snapshot.signedApps.isEmpty,



					snapshot.imported.isEmpty



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
				ToolbarItem(placement: .principal) {
					ZagLocalVPNToolbarStatus()
				}

				ToolbarItem(placement: .topBarLeading) {
					Button {
						withAnimation {
							_editMode = _editMode.isEditing ? .inactive : .active
						}
					} label: {
						Image(systemName: _editMode.isEditing ? "checkmark" : "square.and.pencil")
							.font(.system(size: 20, weight: .semibold))
					}
					.accessibilityLabel(
						_editMode.isEditing
							? Text(.localized("Done"))
							: Text(.localized("Edit"))
					)
				}







				ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            withAnimation { _editMode = .active }
                        } label: {
                            Label("Select Apps", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Picker("Sort Apps", selection: $_sortOrder) {
                            Text("Recently Added").tag(0)
                            Text("Name A–Z").tag(1)
                            Text("Name Z–A").tag(2)
                        }
                        Divider()
                        Button {
                            _showAppDiagnostics = true
                        } label: {
                            Label("RPPairing Diagnostics", systemImage: "stethoscope")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .accessibilityLabel("App Management")
                }

                if _editMode.isEditing {
                    NBToolbarButton(
                        .localized("Delete"),
                        systemImage: "trash",
                        isDisabled: _selectedAppUUIDs.isEmpty
                    ) {
                        _bulkDeleteSelectedApps()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !_editMode.isEditing {
                        Menu {
                            _importActions()
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    ZagProfileToolbarButton()
                        .tint(.primary)
                        .padding(.trailing, -2)
                }


			}



			.modifier(
				ZagLibraryLifecycleModifier(
					editMode: $_editMode,
					scenePhase: scenePhase,
					onRefreshInstalledApps: _refreshInstalledAppsFromDevice,
					onInitialAppear: {
						guard !Self.didPerformInitialDeviceInventory else { return }
						Self.didPerformInitialDeviceInventory = true

						// Let the Apps list commit its first frame before starting device
						// inventory and repository reconciliation. The refresh remains
						// automatic, but no longer competes with the initial tab transition.
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
							// Sources already performs authoritative inventory + update
							// reconciliation at launch. Do not immediately repeat the
							// same expensive work when Apps is opened for the first time.
							// Scene reactivation and explicit refresh still query again.
							switch rppairingCore.installedAppsState {
							case .loaded, .refreshing:
								break
							case .idle, .failed:
								_refreshInstalledAppsFromDevice()
							}
						}
					}
				)
			)

			.navigationDestination(
				isPresented: _repositorySourceIsPresented
			) {
				_repositoryDestination
			}
            .navigationDestination(isPresented: $_isSelfUpdatePresenting) {
                ZagSelfUpdateStatusView()
            }

			.sheet(isPresented: $_showAppDiagnostics) {
                NavigationStack { RPPairingDiagnosticsView() }
            }
            .sheet(isPresented: _animatedUpdatesSheetBinding) {
				_updatesSheetContent
			}

			.sheet(item: $_pendingRemoveApp) { app in
				_removeAppSheetContent(app)
			}

			.sheet(item: $_selectedInfoAppPresenting) { app in
				_infoSheetContent(app)
			}

			.sheet(item: $_selectedInstallAppPresenting) { app in
				_installSheetContent(app)
			}

			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				_signingCoverContent(app)
			}

			.sheet(isPresented: $_isImportingPresenting) {
				_importSheetContent
			}

			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				_downloadAlertActions
			}

			.modifier(
				ZagLibraryTailEventsModifier(
					signedAppUUIDs: _signedApps.map { $0.uuid },
					editMode: _editMode,
					onSignedAppsChange: _updateRepositoryUpdates,
					onInstallApp: {
						if let latest = _signedApps.first {
							_selectedInstallAppPresenting = AnyApp(base: latest)
						}
					},
					onEditModeChange: { mode in
						if mode == .inactive {
							_selectedAppUUIDs.removeAll()
						}
					}
				)
			)



		}



	}












}

private struct ZagLibrarySectionSpacingModifier: ViewModifier {
	@ViewBuilder
	func body(content: Content) -> some View {
		if #available(iOS 17.0, *) {
			content.listSectionSpacing(12)
		} else {
			content
		}
	}
}

private struct ZagLibraryLifecycleModifier: ViewModifier {
	@Binding var editMode: EditMode
	let scenePhase: ScenePhase
	let onRefreshInstalledApps: () -> Void
	let onInitialAppear: () -> Void

	func body(content: Content) -> some View {
		content
			.environment(\.editMode, $editMode)
			.onChange(of: scenePhase) { phase in
				guard phase == .active else { return }
				onRefreshInstalledApps()
			}
			.onAppear {
				onInitialAppear()
			}
	}
}

private struct ZagLibraryTailEventsModifier: ViewModifier {
	let signedAppUUIDs: [String?]
	let editMode: EditMode
	let onSignedAppsChange: () -> Void
	let onInstallApp: () -> Void
	let onEditModeChange: (EditMode) -> Void

	func body(content: Content) -> some View {
		content
			.onChange(of: signedAppUUIDs) { _ in
				onSignedAppsChange()
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in
				onInstallApp()
			}
			.onChange(of: editMode) { mode in
				onEditModeChange(mode)
			}
	}
}

// MARK: - Extension: View



extension LibraryView {

	private var _managedInstalledBundleIDs: Set<String> {
		_managedIDsCache.identifiers(for: _managedInstalledBundleIDsData)
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

	private func _removeSupersededInstalledSignedCopies(
		keeping installed: AppInfoPresentable
	) {
		guard
			let bundleID = installed.identifier,
			!bundleID.isEmpty,
			let installedUUID = installed.uuid
		else {
			return
		}

		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.predicate = NSPredicate(format: "identifier == %@", bundleID)

		guard let copies = try? Storage.shared.context.fetch(request) else {
			return
		}

		for copy in copies where copy.uuid != installedUUID {
			Storage.shared.deleteApp(for: copy)
		}
	}

	private func _beginInstallTransaction(_ signedUUID: String) {
		_transactionSignedUUIDs.insert(signedUUID)
	}

	private func _failInstallTransaction(_ signedUUID: String) {
		withAnimation(.easeInOut(duration: 0.35)) {
			_transactionSignedUUIDs.remove(signedUUID)
		}
	}

	private func _confirmInstalledApp(
		_ app: AppInfoPresentable
	) async -> Bool {
		guard let identifier = app.identifier, !identifier.isEmpty else { return false }
		guard rppairingCore.pairingFileExists else { return false }

		let installedBundleIDs: Set<String>
		do {
			installedBundleIDs = try await withCheckedThrowingContinuation {
				(continuation: CheckedContinuation<Set<String>, Error>) in
				do {
					try rppairingCore.refreshInstalledApps { result in
						continuation.resume(with: result)
					}
				} catch {
					continuation.resume(throwing: error)
				}
			}
		} catch {
			print("[Zag Store Inventory] Post-install confirmation failed: " + error.localizedDescription)
			if let uuid = app.uuid {
				withAnimation(.easeInOut(duration: 0.35)) { _transactionSignedUUIDs.remove(uuid) }
			}
			return false
		}

		guard installedBundleIDs.contains(identifier) else {
			if let uuid = app.uuid {
				withAnimation(.easeInOut(duration: 0.35)) { _transactionSignedUUIDs.remove(uuid) }
			}
			return false
		}

		// Confirm only the app we just installed. Device inventory is not
		// evidence that unrelated App Store apps are Zag Store-managed.
		_markManagedAppInstalled(app)
		_updateRepositoryUpdates()
		_removeSupersededInstalledSignedCopies(keeping: app)

		if let uuid = app.uuid {
			withAnimation(.easeInOut(duration: 0.35)) { _transactionSignedUUIDs.remove(uuid) }
		}
		return true
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
						// Reconcile existing markers only. Do not adopt every
						// App Store app returned by installation_proxy.
						let retained = _managedInstalledBundleIDs.intersection(installedBundleIDs)
						if let encoded = try? JSONEncoder().encode(retained) {
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

	private func _requestRemoveManagedApp(_ app: AppInfoPresentable) {
		_pendingRemoveApp = AnyApp(base: app)
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
    let versionLabel: String

	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#0090FF"

    private var tint: Color {
        ZagWideGamutTint.color(hex: themeColorHex)
    }

	var body: some View {
		GeometryReader { proxy in
			TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
				let cycle = context.date.timeIntervalSinceReferenceDate
					.truncatingRemainder(dividingBy: 6.3)
				let width = max(proxy.size.width, 1)
                // Symmetric optical inset inside the transfer region.
                // The HStack supplies 4pt gaps; retain just 2pt optical clearance.
                let endpointInset: CGFloat = 2
                let travel = max(width - endpointInset * 2, 0)
				let grow = min(max((cycle - 0.42) / 0.48, 0), 1)
				let dissolve = min(max((cycle - 3.00) / 0.52, 0), 1)
				let filament = grow * (1 - dissolve)
				let launchFlare = exp(-pow((cycle - 0.92) / 0.13, 2))
				let impactFlare = exp(-pow((cycle - 2.62) / 0.15, 2))

				ZStack {
                    // Use the EXACT same TimelineView sample and filament
                    // envelope as the line, avoiding phase drift between
                    // independently scheduled animation views.
                    Text(versionLabel)
                        .font(.system(size: 8, weight: .regular))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .opacity(filament)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .top
                        )
                        .offset(y: 9)
                        .allowsHitTesting(false)

					// The electrical path is visible enough to connect both
					// controls, but remains subordinate to the moving energy.
					Capsule()
						.fill(tint)
						.frame(
							width: travel * grow,
							height: 1.0 / UIScreen.main.scale
						)
						.opacity(0.43 * filament)
						.shadow(
							color: tint.opacity(0.34 * filament),
							radius: 2.4
						)
						.frame(maxWidth: .infinity, alignment: .leading)
                        .offset(x: endpointInset)

					// Launch flare starts at the Updates pill on the left.
					ZStack {
						Circle()
							.fill(tint.opacity(0.42))
							.frame(width: 13, height: 13)
							.blur(radius: 4)
						Circle()
							.fill(Color.white)
							.frame(width: 3.5, height: 3.5)
					}
					.opacity(launchFlare)
                    .offset(x: -travel / 2)

					// Keep packet cores in the same Display P3 theme tint as
                    // the filament and Zag Core; no fixed white/blue dots.
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
								.fill(tint.opacity(0.30 * strength))
								.frame(width: tail, height: pulse == 0 ? 4 : 3)
								.blur(radius: 2.4)

							Capsule()
								.fill(tint)
								.frame(width: core, height: pulse == 0 ? 1.8 : 1.3)

							Circle()
								.fill(Color.white)
								.frame(
									width: pulse == 0 ? 4.2 : 3.0,
									height: pulse == 0 ? 4.2 : 3.0
								)
						}
						.opacity(visible ? sin(local * .pi) * strength : 0)
						.offset(x: -travel / 2 + CGFloat(eased) * travel)
					}

					// Reception flare lands beneath the Zag Core on the right.
					ZStack {
						Circle()
							.fill(tint.opacity(0.52))
							.frame(width: 15, height: 15)
							.blur(radius: 4.5)
						Circle()
							.fill(Color.white)
							.frame(width: 4, height: 4)
					}
					.opacity(impactFlare)
                    .offset(x: travel / 2)
				}
				.frame(width: proxy.size.width, height: proxy.size.height)
			}
		}
		.frame(height: 46)
	}
}


private struct ZagUpdatesPillSurface: View {
	var baseColorHex: String = "#2C2C2E"
    var showsBaseFill = true
    // Default keeps the original glint; the receiving Core uses
    // the particle impact timestamp instead of the launch timestamp.
    var chargePhase: Double = 0.82

	@AppStorage("Feather.userTintColor")
	private var themeColorHex: String = "#3F8EF7"

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let time = context.date.timeIntervalSinceReferenceDate
			let cycle = time.truncatingRemainder(dividingBy: 6.3)
			// Keep a slow ambient reflection, then concentrate light at the
			// counter's left edge immediately before the transmission launches.
			let progress = time.truncatingRemainder(dividingBy: 7.4) / 7.4
			let charge = exp(-pow((cycle - chargePhase) / 0.28, 2))

			Circle()
				.fill(showsBaseFill ? Color(hex: baseColorHex) : Color.clear)
				.overlay {
					ZStack {
						ZagUpdatesEdgeGlint(
							progress: progress,
							offset: -0.085,
							length: 0.27,
							color: ZagWideGamutTint.color(hex: themeColorHex),
							opacity: 0.20,
							lineWidth: 3.8
						)
						.blur(radius: 2.7)

						ZagUpdatesEdgeGlint(
							progress: progress,
							offset: -0.038,
							length: 0.15,
							color: ZagWideGamutTint.color(hex: themeColorHex),
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
						Circle()
							.trim(from: 0.43, to: 0.57)
							.stroke(
								ZagWideGamutTint.color(hex: themeColorHex).opacity(0.30 + charge * 0.55),
								style: StrokeStyle(lineWidth: 1.5 + charge * 0.9, lineCap: .round)
							)
							.blur(radius: charge * 1.6)

						Circle()
							.trim(from: 0.485, to: 0.515)
							.stroke(
								Color.white.opacity(charge * 0.92),
								style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
							)
					}
					.mask {
						Circle()
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
					.clipShape(Circle())
				}
		}
	}
}


// The Zag Core is a miniature glass emblem, not a second update counter.
// Its rim reuses the existing 6.3-second charge and edge-glint timing,
// synchronized with ZagUpdateTransferParticles.
// Zag Core 2.0. The mark is the EXACT template UIImage used by the
// native Sources dock tab (ZagSourcesTabIcon.image), never a redrawn Z.
// Keep the original 46pt footprint and 6.3-second transfer/glint cycle.
private struct ZagUpdatesCore: View {
    let baseColorHex: String

    @AppStorage("Feather.userTintColor")
    private var themeColorHex: String = "#0090FF"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        ZagWideGamutTint.color(hex: themeColorHex)
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: reduceMotion
        )) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let cycle = time.truncatingRemainder(dividingBy: 6.3)
            let rotation = reduceMotion ? 0.0 : time / 12.0 * 360.0
            // Updates launch at the left pill; the Zag Core now lights
            // up when the incoming energy reaches it on the right.
            let reception = reduceMotion ? 0.0
                : exp(-pow((cycle - 2.62) / 0.22, 2))
            let energy = reception

            ZStack {
                // A neutral dark optical lens gives the white mark
                // contrast instead of drowning it in a bright blue fill.
                Circle()
                    .fill(.ultraThinMaterial)
                    .padding(1)

                Circle()
                    .fill(
                        colorScheme == .dark
                            ? Color.black.opacity(0.72)
                            : Color.black.opacity(0.78)
                    )
                    .padding(1.5)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                tint.opacity(0.17 + energy * 0.16),
                                tint.opacity(0.065),
                                .clear
                            ],
                            center: .init(x: 0.28, y: 0.18),
                            startRadius: 0,
                            endRadius: 29
                        )
                    )
                    .padding(2)

                // One understated inner orbit; only a short highlight
                // rotates, leaving the center visually quiet.
                Circle()
                    .strokeBorder(tint.opacity(0.22 + energy * 0.10), lineWidth: 0.85)
                    .padding(5.7)

                Circle()
                    .strokeBorder(
                        tint.opacity(energy * 0.42),
                        lineWidth: 1.0
                    )
                    .padding(6)
                    .scaleEffect(1 + energy * 0.12)

                Circle()
                    .trim(from: 0.04, to: 0.20)
                    .stroke(
                        tint.opacity(0.56 + energy * 0.25),
                        style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation))
                    .padding(5.7)

                // The exact same 30x30 UIImage as the bottom dock,
                // rendered at 27pt inside the 46pt glass capsule.
                // White template tint maximizes small-size readability.
                Image(uiImage: ZagSourcesTabIcon.image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: 27, height: 27)
                    // The actual dock Z reacts gently when energy lands.
                    .scaleEffect(1 + energy * 0.045)
                    .shadow(color: tint.opacity(0.25 + energy * 0.55), radius: 1.3 + energy * 2.1)

                // Narrow top-left refraction, away from the Z strokes.
                Ellipse()
                    .fill(.white.opacity(0.15))
                    .frame(width: 16, height: 4)
                    .blur(radius: 2.5)
                    .offset(x: -7, y: -16)

                // Preserve the original rim reflections and timing; the
                // incoming transfer now ends here at the Zag Core.
                ZagUpdatesPillSurface(
                    baseColorHex: baseColorHex,
                    showsBaseFill: false,
                    chargePhase: 2.62
                )
                .allowsHitTesting(false)
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
            // One subtle breathing response, synchronized with the
            // reception flare, without changing layout or hit target.
            .scaleEffect(1 + energy * 0.035)
        }
        .accessibilityHidden(true)
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
				.fill(Color(uiColor: UIColor(displayP3Red: 0, green: 1, blue: 0.22, alpha: 1)))
				.frame(width: 9, height: 9)
				.opacity(0.30 + (energy * 0.70))
				.scaleEffect(0.80 + (energy * 0.30))
				.shadow(
					color: Color(uiColor: UIColor(displayP3Red: 0, green: 1, blue: 0.22, alpha: 1)).opacity(energy * 0.88),
					radius: 4.2 + receive * 3
				)
		}
	}
}


private struct ZagUpdateIconAppearanceModifier: ViewModifier {
	let shouldTint: Bool
	let tintHex: String

	@ViewBuilder
	func body(content: Content) -> some View {
		if shouldTint {
			content
				.saturation(0)
				.contrast(1.25)
				.overlay(
					Color(hex: tintHex)
						.opacity(0.82)
						.blendMode(.color)
				)
		} else {
			content
		}
	}
}

struct ZagUpdateRowSnapshot: Codable, Identifiable {
	let id: String
	let bundleID: String
	let name: String
	let iconURL: String?
	let sourceIconURL: String?
	let releaseDateText: String?
	let releaseNotes: String?
	let metadataText: String?
	let version: String
	// Optional for compatibility with snapshots saved by older Zag Store builds.
	let build: String?
	let completedAt: Date?

	static let availableKey = "ZagStore.availableUpdateRows"
	static let recentKey = "ZagStore.updatedRecentlyRows"

	static func load(_ key: String) -> [Self] {
		guard let data = UserDefaults.standard.data(forKey: key),
			  let rows = try? JSONDecoder().decode([Self].self, from: data)
		else { return [] }
		return rows
	}

	static func save(_ rows: [Self], key: String) {
		guard let data = try? JSONEncoder().encode(rows) else { return }
		UserDefaults.standard.set(data, forKey: key)
	}
}

private struct ZagUpdateRow: View {
	enum Mode {
		case available
		case recentlyUpdated
	}

	let update: UpdateManager.AvailableUpdate
	var mode: Mode = .available
	@Environment(\.colorScheme) private var colorScheme
	@ObservedObject private var pairingCore = ZagRPPairingCore.shared

	@AppStorage("Feather.userTintColor")
	private var selectedColorHex: String = "#4395F8"

	@AppStorage("Feather.shouldTintIcons")
	private var shouldTintIcons: Bool = false

	@AppStorage("Feather.shouldChangeIconsBasedOffStyle")
	private var shouldChangeIconsBasedOffStyle: Bool = false

	@State private var showsFullReleaseNotes = false
	@State private var ringRotation: Double = 0
	@State private var justCompleted = false

	private var useDarkIconAppearance: Bool {
		shouldChangeIconsBasedOffStyle &&
		colorScheme == .dark
	}

	private var zagUpdatesBlue: Color { ZagWideGamutTint.color(hex: selectedColorHex) }

	private var zagUpdatePillBackground: Color {
		colorScheme == .dark
			? Color(hex: "#3E3D42")
			: Color(hex: "#EEEEF0")
	}

	let onSelect: () -> Void
	let onCompleted: () -> Void

	@ObservedObject private var transactionManager =
		ZagUpdateTransactionManager.shared

	private var releaseDate: Date? {
		update.app.currentAppVersion?.date?.date ??
		update.app.currentDate?.date
	}

	private var releaseDateText: String? {
		if mode == .recentlyUpdated {
			return .localized("Today")
		}
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
			return "1 Day Ago"
		case 2:
			return "2 Days Ago"
		case 3:
			return "3 Days Ago"
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

	var snapshot: ZagUpdateRowSnapshot {
		ZagUpdateRowSnapshot(
			id: update.id,
			bundleID: update.app.id ?? update.id,
			name: update.app.currentName,
			iconURL: update.app.iconURL?.absoluteString,
			sourceIconURL: update.source.currentIconURL?.absoluteString,
			releaseDateText: releaseDateText,
			releaseNotes: releaseNotes,
			metadataText: releaseMetadataText,
			version: update.availableVersion,
			build: update.availableBuild,
			completedAt: mode == .recentlyUpdated ? Date() : nil
		)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			HStack(alignment: .center, spacing: 12) {
				appIcon

				VStack(alignment: .leading, spacing: 2) {
					Text(update.app.currentName)
						.zagContentTitleStyle()
						.lineLimit(1)

					if let releaseDateText {
						Text(releaseDateText)
							.font(.system(size: 15))
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
				}

				Spacer(minLength: 8)

				zagUpdateButton
			}

			if let releaseNotes {
				VStack(alignment: .leading, spacing: showsFullReleaseNotes ? 22 : 0) {
					ZStack(alignment: .bottomTrailing) {
						Text(releaseNotes)
							.font(.system(size: 17, weight: .regular))
							.foregroundStyle(.primary)
							.lineLimit(showsFullReleaseNotes ? nil : 2)
							.frame(maxWidth: .infinity, alignment: .leading)
							.mask {
								if showsFullReleaseNotes {
									Rectangle()
								} else {
									HStack(spacing: 0) {
										Rectangle()
										LinearGradient(
											stops: [
												.init(color: .white, location: 0),
												.init(color: .clear, location: 1)
											],
											startPoint: .leading,
											endPoint: .trailing
										)
										.frame(width: 54)
									}
								}
							}
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
		.padding(.bottom, releaseNotes == nil ? 14 : 14)
		.contentShape(Rectangle())
		.onTapGesture {
			onSelect()
		}
	}

	@ViewBuilder
	private var zagUpdateButton: some View {
		let stage = transactionManager.stage(for: update)

		VStack(spacing: 2) {
			ZStack {
				if mode == .recentlyUpdated {
					ZagActionPill(
						title: .localized("Open"),
						backgroundColor: zagUpdatePillBackground
					) {
						if let bundleID = update.app.id {
							UIApplication.openApp(with: bundleID)
						}
					}
				} else if justCompleted {
					ZagActionPill(
						title: .localized("Open"),
						backgroundColor: zagUpdatePillBackground
					) {
						if let bundleID = update.app.id {
							UIApplication.openApp(with: bundleID)
						}
					}
				} else if stage != nil, !isFailed(stage) {
					ZStack {
						Circle()
							.stroke(zagUpdatesBlue.opacity(0.22), lineWidth: 2.3)
						Circle()
							.trim(from: 0.08, to: 0.72)
							.stroke(
								zagUpdatesBlue,
								style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
							)
							.rotationEffect(.degrees(ringRotation - 90))
					}
					.frame(width: 31, height: 31)
					.onAppear {
						ringRotation = 0
						withAnimation(
							.linear(duration: 0.85)
								.repeatForever(autoreverses: false)
						) {
							ringRotation = 360
						}
					}
				} else {
					ZagActionPill(
						title: stage?.title ?? .localized("Update"),
						backgroundColor: zagUpdatePillBackground
					) {
						_startInlineUpdate()
					}
				}
			}
			.frame(width: ZagListLayout.actionWidth, height: ZagListLayout.actionHeight)

			Text(_stageCaption(stage))
				.font(.system(size: 9, weight: .medium))
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.frame(width: 88, height: 11)
				.opacity(_stageCaption(stage).isEmpty ? 0 : 1)
		}
	}

	private func isFailed(_ stage: ZagUpdateTransactionManager.Stage?) -> Bool {
		if case .failed = stage { return true }
		return false
	}

	private func _stageCaption(
		_ stage: ZagUpdateTransactionManager.Stage?
	) -> String {
		switch stage {
		case .downloading:
			return .localized("Downloading…")
		case .importing, .signing, .readyToInstall:
			return .localized("Preparing…")
		case .installing:
			return .localized("Installing…")
		default:
			return ""
		}
	}

	private func _startInlineUpdate() {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		transactionManager.prepare(update) { result in
			switch result {
			case .success(let signedUUID):
				Task {
					do {
						try await transactionManager.installPreparedUpdate(
							signedUUID: signedUUID
						)
						try? pairingCore.refreshInstalledApps()
						withAnimation(.easeInOut(duration: 0.2)) {
							justCompleted = true
						}
						try? await Task.sleep(nanoseconds: 1_000_000_000)
						onCompleted()
					} catch {
						transactionManager.failInstallation(
							update: update,
							error: error
						)
						UIAlertController.showAlertWithOk(
							title: .localized("Update Failed"),
							message: error.localizedDescription
						)
					}
				}

			case .failure(let error):
				UIAlertController.showAlertWithOk(
					title: .localized("Update Failed"),
					message: error.localizedDescription
				)
			}
		}
	}

	@ViewBuilder
	private var appIcon: some View {
		ZStack(alignment: .bottomLeading) {
			ZagRepositoryAppIconView(app: update.app, size: 62)

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


struct ZagUpdatesPopup: View {
	let updates: [UpdateManager.AvailableUpdate]
	var embeddedInAccountNavigation = false

	@State private var completedUpdates: [UpdateManager.AvailableUpdate] = []
	@State private var completedUpdateIDs: Set<String> = []
	@State private var cachedAvailableRows: [ZagUpdateRowSnapshot] =
		ZagUpdateRowSnapshot.load(ZagUpdateRowSnapshot.availableKey)
	@State private var cachedRecentRows: [ZagUpdateRowSnapshot] =
		ZagUpdateRowSnapshot.load(ZagUpdateRowSnapshot.recentKey)
	@ObservedObject private var updateManager = UpdateManager.shared

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
	// Read only by handlers (and passed to SourceAppsView, which observes it).
	// Observing it here re-rendered this view for every refreshed repository.
	private let sourcesViewModel = SourcesViewModel.shared
	@ObservedObject private var pairingCore = ZagRPPairingCore.shared
	@State private var selectedUpdate: UpdateManager.AvailableUpdate?
	@State private var isUpdatingAll = false
	@State private var bulkUpdateProgress = 0
	@State private var bulkUpdateTotal = 0
	@State private var bulkUpdateFailures: [String] = []
	@State private var showBulkUpdateResult = false

	private var popupBackground: Color {
		colorScheme == .dark ? Color(hex: "#1C1C1E") : Color(hex: "#F2F1F6")
	}

	private var sectionBackground: Color {
		colorScheme == .dark ? Color(hex: "#2C2C2E") : Color(hex: "#FFFFFF")
	}

	private var separatorColor: Color {
		colorScheme == .dark ? Color(hex: "#403F44") : Color(hex: "#E7E7E9")
	}

	@AppStorage("Feather.userTintColor") private var themeTintHex: String = "#4395F8"
	private var updatesBlue: Color { ZagWideGamutTint.color(hex: themeTintHex) }

	private var availableUpdates: [UpdateManager.AvailableUpdate] {
		updateManager.visibleUpdates.filter { !completedUpdateIDs.contains($0.id) }
	}

	private var displayedAvailableCount: Int {
		// Popup rows and popup count must describe the same collection.
		// Preserve the persisted badge while the first check is pending.
		updateManager.hasCompletedUpdateCheck
			? availableUpdates.count : updateManager.updateCount
	}

	var body: some View {
		Group {
			if embeddedInAccountNavigation {
				updatesContent
			} else {
				NavigationStack { updatesContent }
			}
		}
	}

	private var updatesContent: some View {
			ZStack {
				popupBackground
					.ignoresSafeArea()

				ScrollView {
					LazyVStack(alignment: .leading, spacing: 18) {
						if displayedAvailableCount > 0 {
							updateAllCard
								.padding(.top, 22)
								.transition(
									.asymmetric(
										insertion: .opacity.combined(with: .move(edge: .top)),
										removal: .opacity.combined(with: .move(edge: .top))
									)
								)
						}

						if !availableUpdates.isEmpty {
							Text(.localized("Available Updates"))
								.font(.headline)
								.foregroundStyle(.secondary)
								.textCase(nil)
								.padding(.leading, 16)
								.padding(.top, 6)
								.padding(.bottom, -8)

							VStack(spacing: 0) {
								ForEach(Array(availableUpdates.enumerated()), id: \.element.id) { index, update in
									ZagUpdateRow(
										update: update,
										onSelect: {
											selectedUpdate = update
										},
										onCompleted: {
											_moveToUpdatedRecently(update)
										}
									)
									.padding(.horizontal, 16)
									.padding(.top, index == 0 ? 8 : 0)
									.transition(
										.asymmetric(
											insertion: .opacity,
											removal: .opacity.combined(with: .move(edge: .top))
										)
									)

									if index < availableUpdates.count - 1 {
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
						} else if updateManager.isRepositoryRefreshInProgress && !cachedAvailableRows.isEmpty {
							Text(.localized("Available Updates"))
								.font(.headline)
								.foregroundStyle(.secondary)
								.textCase(nil)
								.padding(.leading, 16)
								.padding(.top, 6)
								.padding(.bottom, -8)

							ZagCachedUpdateSection(
								rows: cachedAvailableRows,
								sectionBackground: sectionBackground,
								separatorColor: separatorColor,
								isRecent: false
							)
						}

						if !cachedRecentRows.isEmpty {
							Text(.localized("Updated Recently"))
								.font(.headline)
								.foregroundStyle(.secondary)
								.textCase(nil)
								.padding(.leading, 16)
								.padding(.top, 6)
								.padding(.bottom, -8)

							ZagCachedUpdateSection(
								rows: cachedRecentRows,
								sectionBackground: sectionBackground,
								separatorColor: separatorColor,
								isRecent: true
							)
						}
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
			.task {
				_pruneCachedRecent()
				_cacheAvailableRows()
				let bundleIDs = updates.compactMap { $0.app.id }
				try? pairingCore.refreshInstalledAppIcons(bundleIDs: bundleIDs)
			}
			.onReceive(sourcesViewModel.$sources) { _ in
				// Each finished repository publishes. Re-encoding and saving every
				// row snapshot per repository is redundant; cache once it settles.
				guard !sourcesViewModel.isRefreshing else { return }
				_cacheAvailableRows()
			}
			.onReceive(sourcesViewModel.$isRefreshing) { refreshing in
				// @Published sends before the stored value changes.
				guard !refreshing else { return }
				DispatchQueue.main.async { _cacheAvailableRows() }
			}
			.onReceive(updateManager.$updates) { _ in
				// @Published sends before the stored value changes. Cache after
				// publication, or a previous update snapshot may be saved again.
				DispatchQueue.main.async { _cacheAvailableRows() }
			}
			.animation(.easeInOut(duration: 0.35), value: displayedAvailableCount)
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
			.interactiveDismissDisabled(isUpdatingAll || !embeddedInAccountNavigation)
			.alert("Update All", isPresented: $showBulkUpdateResult) {
				Button("OK", role: .cancel) { }
			} message: {
				if bulkUpdateFailures.isEmpty {
					Text("Successfully installed all \(bulkUpdateTotal) updates.")
				} else {
					Text("Installed \(bulkUpdateTotal - bulkUpdateFailures.count) of \(bulkUpdateTotal) updates. Failed: \(bulkUpdateFailures.joined(separator: ", ")). You can retry failed updates individually.")
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					if !embeddedInAccountNavigation {
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
		Button {
			guard !isUpdatingAll, updateManager.hasCompletedUpdateCheck else { return }
			let pending = availableUpdates.filter { update in
				switch ZagUpdateTransactionManager.shared.stage(for: update) {
				case nil, .failed: return true
				default: return false
				}
			}
			guard !pending.isEmpty else { return }
			isUpdatingAll = true
			bulkUpdateTotal = pending.count
			bulkUpdateProgress = 0
			bulkUpdateFailures = []
			Task { await _installAll(pending) }
		} label: {
		HStack {
			Text(isUpdatingAll ? "Updating \(bulkUpdateProgress + 1) of \(bulkUpdateTotal)…" : .localized("Update All"))
				.font(.system(size: 19, weight: .regular))
				.foregroundStyle(updatesBlue)

			Spacer()

			Text(displayedAvailableCount.description)
				.font(.system(size: 14, weight: .regular))
				.foregroundStyle(.white)
				.frame(minWidth: 24, minHeight: 24)
				.padding(.horizontal, 1)
				.background(
					Color(uiColor: UIColor(displayP3Red: 0.92, green: 0.19, blue: 0.15, alpha: 1)),
					in: Capsule()
				)
		}
		.padding(.horizontal, 16)
		.frame(minHeight: 60)
		.background(
			sectionBackground,
			in: RoundedRectangle(cornerRadius: 24, style: .continuous)
		)
		}
		.buttonStyle(.plain)
		.disabled(isUpdatingAll || !updateManager.hasCompletedUpdateCheck)
		.accessibilityElement(children: .combine)
	}

	@MainActor
	private func _installAll(_ pending: [UpdateManager.AvailableUpdate]) async {
		let manager = ZagUpdateTransactionManager.shared
		for update in pending {
			do {
				let signedUUID = try await manager.prepareAsync(update)
				try await manager.installPreparedUpdate(signedUUID: signedUUID)
				_moveToUpdatedRecently(update)
				try? pairingCore.refreshInstalledApps()
			} catch {
				manager.failInstallation(update: update, error: error)
				bulkUpdateFailures.append(update.app.currentName)
			}
			bulkUpdateProgress += 1
		}
		isUpdatingAll = false
		showBulkUpdateResult = true
	}
}


private extension ZagUpdatesPopup {
	func _moveToUpdatedRecently(_ update: UpdateManager.AvailableUpdate) {
		guard !completedUpdateIDs.contains(update.id) else { return }

		let row = _snapshot(for: update, completedAt: Date())
		var recent = ZagUpdateRowSnapshot.load(ZagUpdateRowSnapshot.recentKey)
		recent.removeAll { $0.bundleID == row.bundleID }
		recent.insert(row, at: 0)
		ZagUpdateRowSnapshot.save(recent, key: ZagUpdateRowSnapshot.recentKey)
		cachedRecentRows = recent

		var available = ZagUpdateRowSnapshot.load(ZagUpdateRowSnapshot.availableKey)
		available.removeAll { $0.bundleID == row.bundleID }
		ZagUpdateRowSnapshot.save(available, key: ZagUpdateRowSnapshot.availableKey)
		cachedAvailableRows = available

		withAnimation(.easeInOut(duration: 0.35)) {
			completedUpdateIDs.insert(update.id)
			completedUpdates.removeAll { $0.id == update.id }
			completedUpdates.insert(update, at: 0)
		}
		_cacheAvailableRows()
		updateManager.updateCompletionDidChange()
	}

	func _snapshot(
		for update: UpdateManager.AvailableUpdate,
		completedAt: Date? = nil
	) -> ZagUpdateRowSnapshot {
		let notes =
			update.app.currentAppVersion?.localizedDescription ??
			update.app.versionDescription ??
			update.app.localizedDescription

		var metadata: [String] = []
		if let version = update.app.currentVersion {
			var value = String(format: .localized("Version %@"), version)
			if let build = update.app.currentAppVersion?.build,
			   !build.isEmpty, build != version {
				value += " (\(build))"
			}
			metadata.append(value)
		}
		if let size = update.app.size {
			metadata.append(size.formattedByteCount)
		}

		return ZagUpdateRowSnapshot(
			id: update.id,
			bundleID: update.app.id ?? update.id,
			name: update.app.currentName,
			iconURL: update.app.iconURL?.absoluteString,
			sourceIconURL: update.source.currentIconURL?.absoluteString,
			releaseDateText: nil,
			releaseNotes: notes,
			metadataText: metadata.isEmpty ? nil : metadata.joined(separator: " • "),
			version: update.availableVersion,
			build: update.availableBuild,
			completedAt: completedAt
		)
	}

	func _cacheAvailableRows() {
		// Do not discard the cached cold-start rows until reconciliation is
		// authoritative. A completed empty result must clear a stale cache.
		guard updateManager.hasCompletedUpdateCheck else { return }
		let rows = availableUpdates.map { _snapshot(for: $0) }
		cachedAvailableRows = rows
		ZagUpdateRowSnapshot.save(rows, key: ZagUpdateRowSnapshot.availableKey)
	}

	func _pruneCachedRecent() {
		let cutoff = Calendar.current.date(
			byAdding: .day,
			value: -30,
			to: Date()
		) ?? .distantPast
		let rows = ZagUpdateRowSnapshot
			.load(ZagUpdateRowSnapshot.recentKey)
			.filter { ($0.completedAt ?? .distantPast) >= cutoff }
			.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
		cachedRecentRows = rows
		ZagUpdateRowSnapshot.save(rows, key: ZagUpdateRowSnapshot.recentKey)
	}


}

private struct ZagCachedUpdateSection: View {
	let rows: [ZagUpdateRowSnapshot]
	let sectionBackground: Color
	let separatorColor: Color
	let isRecent: Bool

	var body: some View {
		VStack(spacing: 0) {
			ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
				ZagCachedUpdateRow(row: row, isRecent: isRecent)
					.padding(.horizontal, 16)
					.padding(.top, index == 0 ? 8 : 0)
					.padding(.bottom, isRecent && index == rows.count - 1 ? 16 : 0)

				if index < rows.count - 1 {
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
}

private struct ZagCachedUpdateRow: View {
	let row: ZagUpdateRowSnapshot
	let isRecent: Bool
	@Environment(\.colorScheme) private var colorScheme
	@State private var showsFullReleaseNotes = false

	@AppStorage("Feather.userTintColor") private var themeTintHex: String = "#4395F8"
	private var blue: Color { ZagWideGamutTint.color(hex: themeTintHex) }
	private var pillBackground: Color {
		colorScheme == .dark ? Color(hex: "#3E3D42") : Color(hex: "#EEEEF0")
	}
	private var dateText: String {
		guard let completedAt = row.completedAt else {
			return row.releaseDateText ?? ""
		}
		let days = Calendar.current.dateComponents(
			[.day],
			from: Calendar.current.startOfDay(for: completedAt),
			to: Calendar.current.startOfDay(for: Date())
		).day ?? 0
		switch days {
		case 0: return .localized("Today")
		case 1: return "1 Day Ago"
		case 2: return "2 Days Ago"
		case 3: return "3 Days Ago"
		default:
			let formatter = DateFormatter()
			formatter.locale = .current
			formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
			return formatter.string(from: completedAt)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			HStack(alignment: .center, spacing: 12) {
				ZStack(alignment: .bottomLeading) {
					LazyImage(url: row.iconURL.flatMap(URL.init(string:))) { state in
						if let image = state.image {
							image.resizable().aspectRatio(contentMode: .fill)
						} else {
							Image(systemName: "app.fill")
								.resizable().scaledToFit().padding(10)
								.foregroundStyle(.secondary)
						}
					}
					.frame(width: 62, height: 62)
					.clipShape(RoundedRectangle(cornerRadius: 62 * 0.2677, style: .continuous))

					if let sourceURL = row.sourceIconURL.flatMap(URL.init(string:)) {
						LazyImage(url: sourceURL) { state in
							if let image = state.image {
								image.appIconStyle(
									size: 20,
									isCircle: true,
									background: Color(uiColor: .secondarySystemBackground)
								).offset(x: 46, y: 4)
							}
						}
					}
				}

				VStack(alignment: .leading, spacing: 2) {
					Text(row.name).zagContentTitleStyle().lineLimit(1)
					if !dateText.isEmpty {
						Text(dateText).font(.system(size: 15)).foregroundStyle(.secondary)
					}
				}
				Spacer(minLength: 8)

				ZagActionPill(
					title: .localized(isRecent ? "Open" : "Update"),
					backgroundColor: pillBackground
				) {
					if isRecent {
						UIApplication.openApp(with: row.bundleID)
					}
				}
				.disabled(!isRecent)
			}

			if let notes = row.releaseNotes,
			   !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				VStack(alignment: .leading, spacing: showsFullReleaseNotes ? 22 : 0) {
					ZStack(alignment: .bottomTrailing) {
						Text(notes)
							.font(.system(size: 17, weight: .regular))
							.foregroundStyle(.primary)
							.lineLimit(showsFullReleaseNotes ? nil : 2)
							.frame(maxWidth: .infinity, alignment: .leading)
							.mask {
								if showsFullReleaseNotes {
									Rectangle()
								} else {
									HStack(spacing: 0) {
										Rectangle()
										LinearGradient(
											stops: [
												.init(color: .white, location: 0),
												.init(color: .clear, location: 1)
											],
											startPoint: .leading,
											endPoint: .trailing
										)
										.frame(width: 54)
									}
								}
							}
							.padding(.trailing, showsFullReleaseNotes ? 0 : 42)
						Button(.localized(showsFullReleaseNotes ? "less" : "more")) {
							withAnimation(.easeInOut(duration: 0.2)) {
								showsFullReleaseNotes.toggle()
							}
						}
						.font(.system(size: 17, weight: .regular))
						.foregroundStyle(blue)
					}
					if showsFullReleaseNotes, let metadata = row.metadataText {
						Text(metadata)
							.font(.system(size: 16, weight: .regular))
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.padding(.vertical, 14)
	}
}


private struct ZagLibraryHeader: View {
	let title: String
	let count: Int
	let isCollapsed: Bool
	let onToggle: () -> Void

	var body: some View {
		Button(action: onToggle) {
			HStack(spacing: 8) {
				ZagSectionHeader(
					title: title,
					count: count
				)

				Spacer(minLength: 8)

				Image(systemName: "chevron.down")
					.font(.system(size: 20, weight: .semibold))
					.foregroundStyle(.secondary)
					.frame(width: 44, height: 44)
					.rotationEffect(.degrees(isCollapsed ? -90 : 0))
					.animation(.easeInOut(duration: 0.28), value: isCollapsed)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(Text(title))
		.accessibilityValue(Text(isCollapsed ? "Collapsed" : "Expanded"))
		.accessibilityHint(Text(isCollapsed ? "Expand section" : "Collapse section"))
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
		case installing
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
			case .installing:
				return "Installing"
			case .failed:
				return "Retry"
			}
		}
	}

	@Published private(set) var stages: [String: Stage] = [:]
    struct ActivityRecord: Codable, Identifiable {
        let id: UUID
        let updateID: String
        let status: String
        let detail: String?
        let timestamp: Date
        var appName: String? = nil
        var iconURL: String? = nil
        var sourceIconURL: String? = nil
    }

    @Published private(set) var activityHistory: [ActivityRecord] = []

    private let historyKey = "zagStore.updateActivityHistory.v1"
    private var updateNames: [String: String] = [:]
    private var updateIconURLs: [String: String] = [:]
    private var updateSourceIconURLs: [String: String] = [:]

    private func rememberName(_ update: UpdateManager.AvailableUpdate) {
        updateNames[update.id] = update.app.currentName
        updateIconURLs[update.id] = update.app.iconURL?.absoluteString
        updateSourceIconURLs[update.id] = update.source.currentIconURL?.absoluteString
    }


    // A shared entry point for signing and installation workflows outside
    // the update coordinator. Use the operation UUID, not the bundle ID,
    // so separate operations remain separate in Activity.
    @MainActor
    func recordExternalOperation(id: String, status: String, appName: String?, bundleID: String?, iconURL: String? = nil) {
        let record = ActivityRecord(
            id: UUID(), updateID: id, status: status,
            detail: bundleID, timestamp: Date(), appName: appName, iconURL: iconURL
        )
        activityHistory.insert(record, at: 0)
        if activityHistory.count > 100 {
            activityHistory = Array(activityHistory.prefix(100))
        }
        if let data = try? JSONEncoder().encode(activityHistory) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func recordActivity(updateID: String, status: String, detail: String? = nil, appName: String? = nil) {
        let record = ActivityRecord(id: UUID(), updateID: updateID, status: status,
                                    detail: detail, timestamp: Date(), appName: appName,
                                    iconURL: updateIconURLs[updateID], sourceIconURL: updateSourceIconURLs[updateID])
        activityHistory.insert(record, at: 0)
        if activityHistory.count > 100 {
            activityHistory = Array(activityHistory.prefix(100))
        }
        if let data = try? JSONEncoder().encode(activityHistory) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }



	private struct PendingUpdate {
		let updateID: String
		let importedUUID: String
		let signedUUID: String
		let supersededSignedUUIDs: [String]
	}

	private var pendingBySignedUUID: [String: PendingUpdate] = [:]

	// Signing creates a Core Data record before the device has installed it.
	// Keep the previously installed release as fallback evidence until Gate4
	// confirms success. This is persisted so a failed install stays failed
	// across a cold launch instead of appearing as an already-installed update.
	struct InstallationBaseline: Codable {
		let bundleID: String
		let appName: String
		let installedVersion: String
		let installedBuild: String?
		let targetVersion: String
		let stagedSignedUUIDs: [String]
	}
	private static let installationBaselinesKey = "zagStore.pendingInstallationBaselines.v1"
	private lazy var cachedBaselines: [String: InstallationBaseline] = {
		guard let data = UserDefaults.standard.data(forKey: Self.installationBaselinesKey),
			let stored = try? JSONDecoder().decode([String: InstallationBaseline].self, from: data)
		else { return [:] }
		return stored
	}()
	private lazy var stagedSignedUUIDSet: Set<String> = Set(
		cachedBaselines.values.flatMap { $0.stagedSignedUUIDs }
	)

	private func baselines() -> [String: InstallationBaseline] {
		cachedBaselines
	}

	func pendingInstallationBaseline(bundleID: String) -> InstallationBaseline? {
		baselines()[bundleID]
	}

	func isPendingInstallationSigned(uuid: String?) -> Bool {
		guard let uuid else { return false }
		return stagedSignedUUIDSet.contains(uuid)
	}

	private func recordPendingInstallation(
		_ update: UpdateManager.AvailableUpdate,
		signedUUID: String
	) {
		guard let bundleID = update.app.id, !bundleID.isEmpty else { return }
		var stored = baselines()
		// Preserve the first known installed release through multiple retries,
		// while tracking every prepared IPA that has never been installed.
		if let previous = stored[bundleID] {
			var uuids = previous.stagedSignedUUIDs
			if !uuids.contains(signedUUID) { uuids.append(signedUUID) }
			stored[bundleID] = InstallationBaseline(
				bundleID: bundleID,
				appName: previous.appName,
				installedVersion: previous.installedVersion,
				installedBuild: previous.installedBuild,
				targetVersion: update.availableVersion,
				stagedSignedUUIDs: uuids
			)
		} else {
			stored[bundleID] = InstallationBaseline(
				bundleID: bundleID,
				appName: update.app.currentName,
				installedVersion: update.installedVersion,
				installedBuild: update.installedBuild,
				targetVersion: update.availableVersion,
				stagedSignedUUIDs: [signedUUID]
			)
		}
		cachedBaselines = stored
		stagedSignedUUIDSet = Set(stored.values.flatMap { $0.stagedSignedUUIDs })
		if let data = try? JSONEncoder().encode(stored) {
			UserDefaults.standard.set(data, forKey: Self.installationBaselinesKey)
		}
	}

	private func clearPendingInstallation(bundleID: String?) {
		guard let bundleID else { return }
		var stored = baselines()
		guard stored.removeValue(forKey: bundleID) != nil else { return }
		cachedBaselines = stored
		stagedSignedUUIDSet = Set(stored.values.flatMap { $0.stagedSignedUUIDs })
		if let data = try? JSONEncoder().encode(stored) {
			UserDefaults.standard.set(data, forKey: Self.installationBaselinesKey)
		}
	}

    private init() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let records = try? JSONDecoder().decode([ActivityRecord].self, from: data) {
            activityHistory = Array(records.prefix(100))
        }
    }

	func stage(for update: UpdateManager.AvailableUpdate) -> Stage? {
		stages[update.id]
	}

	func prepare(
		_ update: UpdateManager.AvailableUpdate,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		rememberName(update)
		guard stages[update.id] == nil || isRetryable(update) else {
			return
		}

		// Retry the signed package after a transport failure. Re-downloading
		// and signing would create yet another false installed-state record.
		if isRetryable(update),
			let pending = pendingBySignedUUID.values.first(where: { $0.updateID == update.id }),
			signedApp(uuid: pending.signedUUID) != nil {
			stages[update.id] = .readyToInstall
			completion(.success(pending.signedUUID))
			return
		}

		guard let downloadURL = update.app.currentDownloadUrl else {
			let error = ZagUpdateTransactionError.missingDownloadURL
			stages[update.id] = .failed(error.localizedDescription)
            recordActivity(updateID: update.id, status: "Failed", detail: error.localizedDescription, appName: updateNames[update.id])
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

				guard let certificate = await ZagCertificateSelection.chooseForSigning() else {
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
				recordPendingInstallation(update, signedUUID: signingHandler.uuid)
				// New signed records must not make the device look updated before
				// Gate4 confirms the installation.
				UpdateManager.shared.refresh(
					repositories: Array(SourcesViewModel.shared.sources.values)
				)

				try? FileManager.default.removeItem(at: localURL)

				stages[update.id] = .readyToInstall
                recordActivity(updateID: update.id, status: "Ready to Install", appName: updateNames[update.id])
				completion(.success(signingHandler.uuid))
			} catch {
				if let downloadedFile {
					try? FileManager.default.removeItem(at: downloadedFile)
				}

				stages[update.id] = .failed(error.localizedDescription)
                recordActivity(updateID: update.id, status: "Failed", detail: error.localizedDescription)
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
		guard let pending = pendingBySignedUUID[signedUUID] else {
			throw ZagUpdateTransactionError.signedRecordNotFound
		}

		stages[pending.updateID] = .installing

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

		if let bundleID = signedApp(uuid: signedUUID)?.identifier,
			let baseline = pendingInstallationBaseline(bundleID: bundleID) {
			for staleUUID in baseline.stagedSignedUUIDs where staleUUID != signedUUID {
				if let stale = signedApp(uuid: staleUUID) {
					Storage.shared.deleteApp(for: stale)
				}
			}
		}
		clearPendingInstallation(bundleID: signedApp(uuid: signedUUID)?.identifier)

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
        recordActivity(updateID: pending.updateID, status: "Installed", appName: updateNames[pending.updateID])
        updateNames[pending.updateID] = nil

		// The signed update is now the authoritative local copy. Reconcile the
		// repository snapshot immediately so build-only updates disappear from
		// Apps/Updates without waiting for a source refresh or relaunch.
		UpdateManager.shared.refresh(
			repositories: Array(SourcesViewModel.shared.sources.values)
		)
	}

	func failInstallation(
		update: UpdateManager.AvailableUpdate,
		error: Error
	) {
        rememberName(update)
		stages[update.id] = .failed(error.localizedDescription)
        recordActivity(updateID: update.id, status: "Failed", detail: error.localizedDescription)
		// Do not promote the staged Signed record into installed state.
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



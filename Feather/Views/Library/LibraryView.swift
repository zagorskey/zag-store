//
//  ContentView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
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
	@State private var _updatePulse = false
	
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
	var body: some View {
		NBNavigationView(.localized("Library")) {
			NBListAdaptable {
			if !updateManager.updates.isEmpty {
				FeatherUpdatesSection(
					updates: updateManager.updates,
					isPulsing: $_updatePulse
				)
			}

				if
					!_filteredSignedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					Section {
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
					} header: {
						FeatherLibraryHeader(
							title: .localized("Signed"),
							count: _filteredSignedApps.count
						)
					}
				}
				
				if
					!_filteredImportedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .imported
				{
					Section {
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
					} header: {
						FeatherLibraryHeader(
							title: .localized("Imported"),
							count: _filteredImportedApps.count
						)
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
			.compatSearchScopes($_selectedScope) {
				ForEach(Scope.allCases, id: \.displayName) { scope in
					Text(scope.displayName).tag(scope)
				}
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
					allowedContentTypes:  [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						
						for url in urls {
							let id = "FeatherManualDownload_\(UUID().uuidString)"
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
	private func _updateRepositoryUpdates() {
		UpdateManager.shared.refresh(
			repositories: Array(sourcesViewModel.sources.values),
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

private struct FeatherUpdatesHeader: View {
	let count: Int
	@Binding var isPulsing: Bool

	var body: some View {
		HStack(spacing: 8) {
			Circle()
				.fill(Color.green)
				.frame(width: 9, height: 9)
				.opacity(isPulsing ? 1.0 : 0.25)
				.scaleEffect(isPulsing ? 1.0 : 0.78)
				.shadow(
					color: Color.green.opacity(isPulsing ? 0.65 : 0),
					radius: 4
				)

			Text(.localized("Updates Available"))

			FeatherLabCountBadge(count: count)

			Spacer(minLength: 0)
		}
		.onAppear {
			isPulsing = false

			withAnimation(
				.easeInOut(duration: 0.8)
					.repeatForever(autoreverses: true)
			) {
				isPulsing = true
			}
		}
	}
}


private struct FeatherUpdateRow: View {
	let update: UpdateManager.AvailableUpdate

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

			DownloadButtonView(
				app: update.app,
				title: .localized("Update")
			)
		}
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
					.background(Color(uiColor: .secondarySystemBackground))
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


private struct FeatherUpdatesSection: View {
	let updates: [UpdateManager.AvailableUpdate]
	@Binding var isPulsing: Bool

	var body: some View {
		Section {
			ForEach(updates) { update in
				FeatherUpdateRow(update: update)
			}
		} header: {
			FeatherUpdatesHeader(
				count: updates.count,
				isPulsing: $isPulsing
			)
		}
	}
}


private struct FeatherLibraryHeader: View {
	let title: String
	let count: Int

	var body: some View {
		FeatherLabSectionHeader(
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

//
//  VariedTabbarView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import CoreData

struct VariedTabbarView: View {
	@AppStorage(ZagWallpaperStore.enabledKey) private var wallpaperEnabled = false
	@StateObject private var sourcesViewModel = SourcesViewModel.shared
	@StateObject private var updateManager = UpdateManager.shared

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
	private var sources: FetchedResults<AltSource>

	init() {}

	var body: some View {
		Group {
			if #available(iOS 18, *) {
				ExtendedTabbarView()
			} else {
				TabbarView()
			}
		}
		.background {
			if wallpaperEnabled {
				Color.clear
			}
		}
		.task {
			await updateManager.requestBadgePermission()

			await sourcesViewModel.fetchSources(
				sources,
				refresh: true
			)
		}
		.onReceive(sourcesViewModel.$sources) { _ in
			// SourcesViewModel commits the repository snapshot and its
			// derived update state together after a refresh completes.
			// Do not recalculate here: @Published sends before assignment,
			// which would momentarily evaluate the previous/empty snapshot
			// and erase the last known Updates state while refreshing.
		}
	}
}

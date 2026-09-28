//
//  VariedTabbarView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import CoreData

struct VariedTabbarView: View {
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
		.task {
			await updateManager.requestBadgePermission()

			await sourcesViewModel.fetchSources(
				sources,
				refresh: true
			)

			refreshUpdates()
		}
		.onReceive(sourcesViewModel.$sources) { _ in
			refreshUpdates()
		}
	}

	private func refreshUpdates() {
		updateManager.refresh(
			repositories: Array(
				sourcesViewModel.sources.values
			)
		)
	}
}

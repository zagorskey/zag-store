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

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [],
		animation: .snappy
	)
	private var signedApps: FetchedResults<Signed>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [],
		animation: .snappy
	)
	private var importedApps: FetchedResults<Imported>

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
		.onChange(of: signedApps.map { $0.uuid }) { _ in
			refreshUpdates()
		}
		.onChange(of: importedApps.map { $0.uuid }) { _ in
			refreshUpdates()
		}
	}

	private func refreshUpdates() {
		updateManager.refresh(
			repositories: Array(
				sourcesViewModel.sources.values
			),
			signedApps: Array(signedApps),
			importedApps: Array(importedApps)
		)
	}
}

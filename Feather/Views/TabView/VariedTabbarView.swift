//
//  VariedTabbarView.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import CoreData

struct VariedTabbarView: View {
	@StateObject private var sourcesViewModel = SourcesViewModel.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [
			NSSortDescriptor(keyPath: \AltSource.name, ascending: true)
		],
		animation: .snappy
	) private var sources: FetchedResults<AltSource>

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
			await sourcesViewModel.fetchSources(sources, refresh: true)
		}
	}
}

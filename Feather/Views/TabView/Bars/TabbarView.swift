//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI

struct TabbarView: View {
	@AppStorage("zagStore.navigation.selectedTab") private var selectedTabRawValue = TabEnum.sources.rawValue

	private var selectedTab: Binding<TabEnum> {
		Binding(
			get: {
				TabEnum(rawValue: selectedTabRawValue) ?? .sources
			},
			set: { tab in
				let previousValue = selectedTabRawValue
				if tab == .sources,
				   previousValue != TabEnum.sources.rawValue {
					UserDefaults.standard.removeObject(
						forKey: "zagStore.navigation.sourcesRoute"
					)
					UserDefaults.standard.removeObject(
						forKey: "zagStore.navigation.sourcesAppRoute"
					)
				}
				selectedTabRawValue = tab.rawValue
			}
		)
	}

	var body: some View {
		TabView(selection: selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.tag(tab)
			}
		}
	}
}

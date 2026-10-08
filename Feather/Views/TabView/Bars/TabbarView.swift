//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI

struct TabbarView: View {
	@AppStorage(ZagPageStartupPolicy.rememberLastPageKey) private var rememberLastPage = true
	@State private var selectedTabValue = ZagPageStartupPolicy.initialTab

	private var selectedTab: Binding<TabEnum> {
		Binding(
			get: { selectedTabValue },
			set: { tab in
				selectedTabValue = tab
				if rememberLastPage {
					UserDefaults.standard.set(
						tab.rawValue,
						forKey: ZagPageStartupPolicy.lastPageKey
					)
				}
			}
		)
	}

	var body: some View {
		TabView(selection: selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						if tab == .sources {
                            Label {
                                Text(tab.title)
                            } icon: {
                                ZagSourcesTabIcon.label
                            }
                        } else {
                            Label(tab.title, systemImage: tab.icon)
                        }
					}
					.tag(tab)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .zagStoreRouteRequested)) { note in
			guard let route = note.object as? ZagStoreRoute,
			      let tab = TabEnum(rawValue: route.tab)
			else { return }
			selectedTab.wrappedValue = tab
		}
	}
}

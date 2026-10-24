//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI

struct TabbarView: View {
	@StateObject private var updateManager = UpdateManager.shared
	@AppStorage("Feather.userTintColor") private var themeTintHex = "#0090FF"
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
                        } else if tab == .library {
                            Label {
                                Text(tab.title)
                            } icon: {
                                ZagAppsTabIcon(
                                    hasUpdates: updateManager.hasVisibleUpdates,
                                    isSelected: selectedTabValue == tab,
                                    tintHex: themeTintHex
                                )
                            }
                        } else if tab == .discover || tab == .games || tab == .activity {
                            Label {
                                Text(tab.title)
                            } icon: {
                                switch tab {
                                case .discover: ZagPrimaryTabIcons.label(for: .discover)
                                case .games: ZagPrimaryTabIcons.label(for: .games)
                                case .activity: ZagPrimaryTabIcons.label(for: .activity)
                                default: EmptyView()
                                }
                            }
                        } else {
                            Label(tab.title, systemImage: tab.icon)
                        }
					}
					.tag(tab)
			}
		}
		.onOpenURL { url in
            if let tab = TabEnum.tab(for: url) {
                selectedTab.wrappedValue = tab
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

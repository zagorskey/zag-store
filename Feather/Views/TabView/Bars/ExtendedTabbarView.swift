//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI
import NukeUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@AppStorage("Feather.tabCustomization") var customization = TabViewCustomization()
	// Passed to SourceAppsView, which observes it. This container never
	// reads repository state, so it must not re-render on every publication.
	private let viewModel = SourcesViewModel.shared
	@StateObject private var updateManager = UpdateManager.shared
	@StateObject private var selfUpdateCoordinator = ZagSelfUpdateCoordinator.shared
	@AppStorage("Feather.userTintColor") private var themeTintHex = "#0090FF"
	@AppStorage(ZagPageStartupPolicy.rememberLastPageKey) private var rememberLastPage = true
	@AppStorage(ZagDockConfiguration.storageKey) private var dockTabs = ""
	@State private var selectedTabRawValue = ZagPageStartupPolicy.initialTab.rawValue
	@AppStorage(ZagGlassDockSettings.enabledKey) private var glassDockEnabled = false
	@StateObject private var dockSearch = ZagDockSearch()
	@StateObject private var glassDockState = ZagGlassDockState()

	/// Settings → Bottom Dock → Six-Icon Dock, on iPhone with iOS 26.
	private var usesGlassDock: Bool {
		ZagGlassDockSettings.isSupported && glassDockEnabled && horizontalSizeClass == .compact
	}

	private func dockPage(_ tab: TabEnum) -> some View {
		TabEnum.view(for: tab).zagGlassDockPage(tab, search: usesGlassDock ? dockSearch : nil)
	}
	
	@State private var _isAddingPresenting = false

	private var selectedTab: Binding<String> {
		Binding(
			get: { selectedTabRawValue },
			set: { newValue in
				selectedTabRawValue = newValue
				if rememberLastPage {
					UserDefaults.standard.set(
						newValue,
						forKey: ZagPageStartupPolicy.lastPageKey
					)
				}
			}
		)
	}

	/// The selection as the dock sets it: the only path that slides pages.
	private var dockSelection: Binding<String> {
		Binding(
			get: { selectedTabRawValue },
			set: { newValue in
				ZagPageSlide.dockSelectionWillChange(
					from: selectedTabRawValue,
					to: newValue,
					order: ZagDockConfiguration.tabs.map(\.rawValue)
				)
				selectedTab.wrappedValue = newValue
			}
		)
	}

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
		
	var body: some View {
		TabView(selection: dockSelection) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				if tab == .sources {
                    Tab(value: tab.rawValue) {
                        dockPage(tab)
                    } label: {
                        Label {
                            Text(tab.title)
                        } icon: {
                            ZagSourcesTabIcon.label
                        }
                    }
                } else if tab == .library {
                    Tab(value: tab.rawValue) {
                        dockPage(tab)
                    } label: {
                        Label {
                            Text(tab.title)
                        } icon: {
                            ZagAppsTabIcon(
                                hasUpdates: updateManager.hasVisibleUpdates,
                                hasStoreUpdate: selfUpdateCoordinator.availableRelease != nil,
                                isSelected: selectedTabRawValue == tab.rawValue,
                                tintHex: themeTintHex
                            )
                        }
                    }
                } else if tab == .discover || tab == .games || tab == .activity {
                    Tab(value: tab.rawValue) {
                        dockPage(tab)
                    } label: {
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
                    }
                } else if tab == .settings {
                    Tab(value: tab.rawValue) {
                        dockPage(tab)
                    } label: {
                        Label {
                            Text(tab.title)
                        } icon: {
                            ZagPrimaryTabIcons.label(for: .settings)
                        }
                    }
                } else {
                    Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
                        dockPage(tab)
                    }
                }
			}
			
			ForEach(TabEnum.customizableTabs, id: \.hashValue) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
					TabEnum.view(for: tab)
				}
				.customizationID("tab.\(tab.rawValue)")
				.defaultVisibility(.hidden, for: .tabBar)
				.customizationBehavior(.reorderable, for: .tabBar, .sidebar)
				.hidden(horizontalSizeClass == .compact)
			}
			
			TabSection("Sources") {
				Tab(.localized("All Repositories"), systemImage: "globe", value: "sources.allRepositories") {
					NavigationStack {
						SourceAppsView(object: Array(_sources), viewModel: viewModel)
					}
				}
				
				ForEach(_sources, id: \.identifier) { source in
					Tab(value: "sources.repository.\(source.identifier ?? source.objectID.uriRepresentation().absoluteString)") {
						NavigationStack {
							SourceAppsView(object: [source], viewModel: viewModel)
						}
					} label: {
						_icon(source.name ?? .localized("Unknown"), iconUrl: source.iconURL)
					}
					.swipeActions {
						Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
							Storage.shared.deleteSource(for: source)
						}
					}
				}
			}
			.sectionActions {
				Button(.localized("Add Source"), systemImage: "plus") {
					_isAddingPresenting = true
				}
			}
			.defaultVisibility(.hidden, for: .tabBar)
			.hidden(horizontalSizeClass == .compact)
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
		.modifier(ZagDockShrinkOnScroll())
		.overlay(alignment: .bottom) {
			if #available(iOS 26.0, *), usesGlassDock {
				glassDock
			}
		}
		.onChange(of: selectedTabRawValue) { _ in
			dockSearch.pageChanged()
			glassDockState.pageChanged()
			if usesGlassDock { dockSearch.applyDockInsets() }
		}
		.onChange(of: usesGlassDock) { uses in
			if uses { dockSearch.startReservingDock() } else { dockSearch.stopReservingDock() }
		}
		.onAppear { ZagPageSlide.attachToDock() }
		.onChange(of: dockTabs) { _ in
            if !ZagDockConfiguration.tabs.contains(TabEnum(rawValue: selectedTabRawValue) ?? .discover) {
                selectedTabRawValue = ZagDockConfiguration.tabs.first?.rawValue ?? TabEnum.discover.rawValue
            }
        }
		.onOpenURL { url in
            if let tab = TabEnum.tab(for: url) {
                selectedTab.wrappedValue = (ZagDockConfiguration.tabs.contains(tab) ? tab : (ZagDockConfiguration.tabs.first ?? .discover)).rawValue
            }
        }
		.onReceive(NotificationCenter.default.publisher(for: .zagStoreRouteRequested)) { note in
			guard let route = note.object as? ZagStoreRoute else { return }
			selectedTab.wrappedValue = (ZagDockConfiguration.tabs.contains(TabEnum(rawValue: route.tab) ?? .discover) ? route.tab : (ZagDockConfiguration.tabs.first ?? .discover).rawValue)
		}
		.sheet(isPresented: $_isAddingPresenting) {
			SourcesAddView()
				.presentationDetents([.medium])
		}
	}
	
	@available(iOS 26.0, *)
	private var glassDock: some View {
		GeometryReader { proxy in
			let safeBottom = proxy.safeAreaInsets.bottom
			ZagGlassDock(
				tabs: ZagDockConfiguration.tabs,
				selection: selectedTabRawValue,
				hasUpdates: updateManager.hasVisibleUpdates,
				hasStoreUpdate: selfUpdateCoordinator.availableRelease != nil,
				tintHex: themeTintHex,
				safeBottom: safeBottom,
				select: { tab in dockSelection.wrappedValue = tab.rawValue },
				search: dockSearch,
				state: glassDockState
			)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
			.ignoresSafeArea(.container, edges: .bottom)
			.onAppear {
				dockSearch.dockReserve = ZagGlassDockMetrics.reserve(safeBottom: safeBottom)
				dockSearch.startReservingDock()
				glassDockState.attach()
			}
			.onChange(of: safeBottom) { value in
				dockSearch.dockReserve = ZagGlassDockMetrics.reserve(safeBottom: value)
			}
		}
		// The keyboard covers the dock rather than lifting it.
		.ignoresSafeArea(.keyboard)
	}

	@ViewBuilder
	private func _icon(_ title: String, iconUrl: URL?) -> some View {
		Label {
			Text(title)
		} icon: {
			if let iconURL = iconUrl {
				LazyImage(url: iconURL) { state in
					if let image = state.image {
						image
					} else {
						standardIcon
					}
				}
				.processors([.resize(width: 14), .circle()])
			} else {
				standardIcon
			}
		}
	}

	
	var standardIcon: some View {
		Image(systemName: "app.dashed")
	}
}


/// Settings → Zag Store → Bottom Dock → Shrink on Scroll: iOS 26's own
/// tab bar minimisation, on scroll down.
@available(iOS 18, *)
private struct ZagDockShrinkOnScroll: ViewModifier {
	@AppStorage(ZagDockConfiguration.shrinkOnScrollKey) private var enabled = false

	func body(content: Content) -> some View {
		if #available(iOS 26.0, *) {
			content.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
		} else {
			content
		}
	}
}

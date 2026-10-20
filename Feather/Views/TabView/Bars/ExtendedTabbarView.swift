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
	@StateObject var viewModel = SourcesViewModel.shared
	@StateObject private var updateManager = UpdateManager.shared
	@AppStorage(ZagPageStartupPolicy.rememberLastPageKey) private var rememberLastPage = true
	@State private var selectedTabRawValue = ZagPageStartupPolicy.initialTab.rawValue
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dockCompact = false
    @State private var lastScrollTranslation: CGFloat = 0
    @State private var scrollDirection: CGFloat = 0
    @State private var directionalScrollDistance: CGFloat = 0
	
	@State private var _isAddingPresenting = false

	private var selectedTab: Binding<String> {
		Binding(
			get: { selectedTabRawValue },
			set: { newValue in
				selectedTabRawValue = newValue
                expandDock()
				if rememberLastPage {
					UserDefaults.standard.set(
						newValue,
						forKey: ZagPageStartupPolicy.lastPageKey
					)
				}
			}
		)
	}

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
		
	var body: some View {
		TabView(selection: selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				if tab == .sources {
                    Tab(value: tab.rawValue) {
                        tabDestination(for: tab)
                    } label: {
                        Label {
                            Text(tab.title)
                        } icon: {
                            ZagSourcesTabIcon.label
                        }
                    }
                } else {
                    Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
                        tabDestination(for: tab)
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
        // The native tab bar remains the selection host, but the compact-width
        // dock is drawn separately so its labels and capsule can actually resize.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if horizontalSizeClass == .compact {
                zagDock
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
        }
        .overlay(alignment: .bottom) {
            // On iPad preserve the existing native dock indicator.
            if horizontalSizeClass != .compact, updateManager.hasVisibleUpdates {
                GeometryReader { proxy in
                    let inset: CGFloat = 30
                    let itemWidth = (proxy.size.width - inset * 2) / CGFloat(TabEnum.defaultTabs.count)
                    Circle()
                        .fill(updatesDotColor)
                        .frame(width: 7, height: 7)
                        .position(x: inset + itemWidth * 2.5 + 12,
                                  y: proxy.size.height - 55)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }
        }
		.tabViewCustomization($customization)
		.onOpenURL { url in
            if let tab = TabEnum.tab(for: url) {
                selectedTab.wrappedValue = tab.rawValue
            }
        }
		.onReceive(NotificationCenter.default.publisher(for: .zagStoreRouteRequested)) { note in
			guard let route = note.object as? ZagStoreRoute else { return }
			selectedTab.wrappedValue = route.tab
		}
		.sheet(isPresented: $_isAddingPresenting) {
			SourcesAddView()
				.presentationDetents([.medium])
		}
	}
	
 
    private var updatesDotColor: Color {
        Color(uiColor: UIColor(displayP3Red: 1, green: 0.12, blue: 0.16, alpha: 1))
    }

    private var dockTint: Color {
        ZagWideGamutTint.color(hex: themeColorHex)
    }

    // Tab selection, deep links, persistence, and the existing page hierarchy
    // remain native. Only the visual dock is custom on compact-width devices.
    @ViewBuilder
    private func tabDestination(for tab: TabEnum) -> some View {
        if horizontalSizeClass == .compact {
            TabEnum.view(for: tab)
                .toolbar(.hidden, for: .tabBar)
                .simultaneousGesture(dockScrollGesture, including: .all)
        } else {
            // Retain iPad's native sidebar and tab bar.
            TabEnum.view(for: tab)
        }
    }

    private var dockScrollGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard horizontalSizeClass == .compact else { return }
                let delta = value.translation.height - lastScrollTranslation
                lastScrollTranslation = value.translation.height
                // Ignore horizontal navigation and incidental diagonal gestures.
                guard abs(value.translation.height) > abs(value.translation.width) * 1.2,
                      abs(delta) > 0.5 else { return }
                let direction: CGFloat = delta > 0 ? 1 : -1
                if direction != scrollDirection {
                    scrollDirection = direction
                    directionalScrollDistance = 0
                }
                directionalScrollDistance += abs(delta)
                guard directionalScrollDistance >= 16 else { return }
                directionalScrollDistance = 0
                let shouldCompact = direction < 0
                guard dockCompact != shouldCompact else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.33, dampingFraction: 0.86)) {
                    dockCompact = shouldCompact
                }
            }
            .onEnded { _ in
                lastScrollTranslation = 0
                scrollDirection = 0
                directionalScrollDistance = 0
            }
    }

    private func expandDock() {
        guard dockCompact else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.33, dampingFraction: 0.86)) {
            dockCompact = false
        }
    }

    private var zagDock: some View {
        HStack(spacing: 0) {
            ForEach(TabEnum.defaultTabs, id: \.rawValue) { tab in
                let selected = selectedTabRawValue == tab.rawValue
                Button {
                    // Even tapping the already-selected icon re-expands the dock.
                    selectedTab.wrappedValue = tab.rawValue
                    expandDock()
                } label: {
                    ZStack(alignment: .top) {
                        Group {
                            if tab == .sources {
                                Image(uiImage: ZagSourcesTabIcon.image)
                                    .resizable()
                                    .renderingMode(.template)
                                    .interpolation(.high)
                                    .frame(width: dockCompact ? 19 : 22,
                                           height: dockCompact ? 19 : 22)
                            } else {
                                Image(systemName: tab.icon)
                                    .font(.system(size: dockCompact ? 18 : 20, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                            }
                        }
                        .foregroundStyle(selected ? dockTint : Color.primary.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .frame(height: 27)
                        .padding(.top, dockCompact ? 7 : 8)

                        if selected && !dockCompact {
                            Text(tab.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(dockTint)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 36)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: dockCompact ? 43 : 62)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.primary.opacity(dockCompact ? 0.13 : 0.075))
                                .padding(.horizontal, 3)
                                .padding(.vertical, dockCompact ? 3 : 4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if tab == .library && updateManager.hasVisibleUpdates {
                            Circle()
                                .fill(updatesDotColor)
                                .frame(width: 7, height: 7)
                                .offset(x: -12, y: dockCompact ? 6 : 8)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint("Select tab")
            }
        }
        .frame(maxWidth: dockCompact ? 292 : 360)
        .background {
            if #available(iOS 26.0, *) {
                Capsule().glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(.regularMaterial)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            }
        }
        .shadow(color: .black.opacity(0.13), radius: 12, y: 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
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


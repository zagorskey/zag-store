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
    @Environment(\.colorScheme) private var colorScheme
    @State private var previousScrollDirection = 0
    @State private var directionalScrollDistance: CGFloat = 0
	
	@State private var _isAddingPresenting = false

	private var selectedTab: Binding<String> {
		Binding(
			get: { selectedTabRawValue },
			set: { newValue in
				selectedTabRawValue = newValue
                expandDock()
                previousScrollDirection = 0
                directionalScrollDistance = 0
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
                .environment(\.zagDockDidScroll, { oldOffset, newOffset in
                    guard selectedTabRawValue == tab.rawValue else { return }
                    reportDockScroll(from: oldOffset, to: newOffset)
                })
        } else {
            // Retain iPad's native sidebar and tab bar.
            TabEnum.view(for: tab)
        }
    }

    // Driven by the list's real scroll offset, not a competing drag gesture.
    private func reportDockScroll(from oldOffset: CGFloat, to newOffset: CGFloat) {
        guard horizontalSizeClass == .compact,
              oldOffset.isFinite, newOffset.isFinite else { return }
        let delta = newOffset - oldOffset
        guard abs(delta) >= 1, abs(delta) < 120 else { return }
        if newOffset <= 3 {
            directionalScrollDistance = 0
            previousScrollDirection = 0
            expandDock()
            return
        }
        let direction = delta > 0 ? 1 : -1
        if direction != previousScrollDirection {
            previousScrollDirection = direction
            directionalScrollDistance = 0
        }
        directionalScrollDistance += abs(delta)
        guard directionalScrollDistance >= 16 else { return }
        directionalScrollDistance = 0
        let shouldCompact = direction > 0
        guard dockCompact != shouldCompact else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.33, dampingFraction: 0.86)) {
            dockCompact = shouldCompact
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
                    // Tapping any destination restores the expanded dock.
                    selectedTab.wrappedValue = tab.rawValue
                    expandDock()
                } label: {
                    VStack(spacing: dockCompact ? 1 : 3) {
                        Group {
                            if tab == .sources {
                                Image(uiImage: ZagSourcesTabIcon.image)
                                    .resizable()
                                    .renderingMode(.template)
                                    .interpolation(.high)
                                    .frame(width: 25, height: 25)
                            } else {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 23, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                            }
                        }
                        .frame(height: 27)

                        // Retain the original Zag Store layout: all five
                        // destination titles remain visible.
                        Text(tab.title)
                            .font(.system(size: dockCompact ? 9 : 10,
                                          weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .foregroundStyle(selected ? dockTint : Color.primary.opacity(0.93))
                    .frame(maxWidth: .infinity)
                    .frame(height: dockCompact ? 50 : 64)
                    .background {
                        if selected {
                            Capsule()
                                .fill(colorScheme == .dark
                                      ? Color.black.opacity(0.43)
                                      : Color.white.opacity(0.58))
                                .padding(.horizontal, 2)
                                .padding(.vertical, 2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if tab == .library && updateManager.hasVisibleUpdates {
                            Circle()
                                .fill(updatesDotColor)
                                .frame(width: 7, height: 7)
                                .offset(x: -12, y: dockCompact ? 6 : 9)
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
        // The earlier successful layout animation: the capsule and the
        // five item positions interpolate together, rather than scaling
        // the whole rendered tab bar.
        .frame(maxWidth: dockCompact ? 312 : 396)
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


// The real list/ScrollView reports its content offset through this lightweight
// environment action. It is inert when used outside the main five-tab host.
private struct ZagDockScrollActionKey: EnvironmentKey {
    static var defaultValue: (CGFloat, CGFloat) -> Void { { _, _ in } }
}

extension EnvironmentValues {
    var zagDockDidScroll: (CGFloat, CGFloat) -> Void {
        get { self[ZagDockScrollActionKey.self] }
        set { self[ZagDockScrollActionKey.self] = newValue }
    }
}

private struct ZagDockScrollReportingModifier: ViewModifier {
    @Environment(\.zagDockDidScroll) private var didScroll

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(
                for: CGFloat.self,
                of: { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                },
                action: { oldOffset, newOffset in
                    didScroll(oldOffset, newOffset)
                }
            )
        } else {
            content
        }
    }
}

extension View {
    func zagTrackDockScrolling() -> some View {
        modifier(ZagDockScrollReportingModifier())
    }
}

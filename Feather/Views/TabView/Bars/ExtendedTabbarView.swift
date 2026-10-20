//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI
import NukeUI
import UIKit

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@AppStorage("Feather.tabCustomization") var customization = TabViewCustomization()
	@StateObject var viewModel = SourcesViewModel.shared
	@StateObject private var updateManager = UpdateManager.shared
	@AppStorage(ZagPageStartupPolicy.rememberLastPageKey) private var rememberLastPage = true
	@State private var selectedTabRawValue = ZagPageStartupPolicy.initialTab.rawValue
    @State private var dockIsCompact = false
    @State private var previousDragY: CGFloat = 0
    @State private var accumulatedScroll: CGFloat = 0
    @State private var previousDirection: CGFloat = 0
	
	@State private var _isAddingPresenting = false

	private var selectedTab: Binding<String> {
		Binding(
			get: { selectedTabRawValue },
			set: { newValue in
				selectedTabRawValue = newValue
                dockIsCompact = false
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
                        TabEnum.view(for: tab)
                            .simultaneousGesture(dockDirectionGesture, including: .all)
                    } label: {
                        Label {
                            Text(tab.title)
                        } icon: {
                            ZagSourcesTabIcon.label
                        }
                    }
                } else {
                    Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
                        TabEnum.view(for: tab)
                            .simultaneousGesture(dockDirectionGesture, including: .all)
                    }
                }
			}
			
			ForEach(TabEnum.customizableTabs, id: \.hashValue) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
					TabEnum.view(for: tab)
                            .simultaneousGesture(dockDirectionGesture, including: .all)
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
        .background {
            if horizontalSizeClass == .compact {
                ZagNativeDockScaleBridge(compact: dockIsCompact)
                    .frame(width: 0, height: 0)
            }
        }
		.overlay(alignment: .bottom) {
			if horizontalSizeClass == .compact, updateManager.hasVisibleUpdates {
				GeometryReader { proxy in
					// The native floating tab bar keeps its items inside a
					// horizontal content inset. Preserve the original indicator
					// geometry: 12pt to the right of the Apps icon centre.
					let tabContentInset: CGFloat = 30
					let contentWidth = proxy.size.width - (tabContentInset * 2)
					let itemWidth = contentWidth / CGFloat(TabEnum.defaultTabs.count)
					Circle()
						.fill(Color(uiColor: UIColor(displayP3Red: 1, green: 0.12, blue: 0.16, alpha: 1)))
						.frame(width: 7, height: 7)
						.position(
							x: tabContentInset + itemWidth * 2.5 + 12,
							y: proxy.size.height - 55
						)
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
	
    private var dockDirectionGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard horizontalSizeClass == .compact,
                      abs(value.translation.height) > abs(value.translation.width) * 1.3 else { return }
                let delta = value.translation.height - previousDragY
                previousDragY = value.translation.height
                guard abs(delta) > 0.5 else { return }
                let direction: CGFloat = delta > 0 ? 1 : -1
                if direction != previousDirection {
                    accumulatedScroll = 0
                    previousDirection = direction
                }
                accumulatedScroll += abs(delta)
                guard accumulatedScroll >= 22 else { return }
                accumulatedScroll = 0
                let compact = direction < 0
                if dockIsCompact != compact { dockIsCompact = compact }
            }
            .onEnded { _ in
                previousDragY = 0
                previousDirection = 0
                accumulatedScroll = 0
            }
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


// Apply a transform to the existing UIKit tab bar rather than recreating it.
// Its Liquid Glass material, labels, symbols, badges and tab interactions
// remain exactly as provided by the system.
@available(iOS 18, *)
private struct ZagNativeDockScaleBridge: UIViewRepresentable {
    let compact: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let compact = compact
        DispatchQueue.main.async {
            guard let window = view.window,
                  let tabBar = findTabBar(in: window.rootViewController) else { return }
            let transform = compact
                ? CGAffineTransform(scaleX: 0.86, y: 0.84)
                : .identity
            guard tabBar.transform != transform else { return }
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.30,
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                tabBar.transform = transform
            }
        }
    }

    private func findTabBar(in controller: UIViewController?) -> UITabBar? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs.tabBar }
        for child in controller.children {
            if let found = findTabBar(in: child) { return found }
        }
        if let presented = controller.presentedViewController {
            return findTabBar(in: presented)
        }
        return nil
    }
}

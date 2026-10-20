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
    @State private var compactDock = false
    @State private var lastScrollOffset: CGFloat?
    @State private var scrollDirection = 0
    @State private var scrollTravel: CGFloat = 0
	
	@State private var _isAddingPresenting = false

	private var selectedTab: Binding<String> {
		Binding(
			get: { selectedTabRawValue },
			set: { newValue in
				selectedTabRawValue = newValue
                compactDock = false
                lastScrollOffset = nil
                scrollTravel = 0
                scrollDirection = 0
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
                        nativeDestination(for: tab)
                    } label: {
                        Label {
                            Text(tab.title)
                        } icon: {
                            ZagSourcesTabIcon.label
                        }
                    }
                } else {
                    Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
                        nativeDestination(for: tab)
                    }
                }
			}
			
			ForEach(TabEnum.customizableTabs, id: \.hashValue) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
					nativeDestination(for: tab)
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
                ZagNativeDockTransformBridge(compact: compactDock)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
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
	
    @ViewBuilder
    private func nativeDestination(for tab: TabEnum) -> some View {
        TabEnum.view(for: tab)
            .environment(\.zagDockDidScroll, { oldOffset, newOffset in
                guard selectedTabRawValue == tab.rawValue else { return }
                trackNativeDockScroll(old: oldOffset, new: newOffset)
            })
    }

    private func trackNativeDockScroll(old: CGFloat, new: CGFloat) {
        guard horizontalSizeClass == .compact, new.isFinite else { return }
        if new <= 3 {
            lastScrollOffset = new
            scrollDirection = 0
            scrollTravel = 0
            if compactDock { compactDock = false }
            return
        }
        guard let last = lastScrollOffset else {
            lastScrollOffset = new
            return
        }
        lastScrollOffset = new
        let delta = new - last
        guard abs(delta) >= 2, abs(delta) < 70 else { return }
        let direction = delta > 0 ? 1 : -1
        if direction != scrollDirection {
            scrollDirection = direction
            scrollTravel = 0
        }
        scrollTravel += abs(delta)
        guard scrollTravel >= 26 else { return }
        scrollTravel = 0
        let compact = direction > 0
        if compactDock != compact { compactDock = compact }
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


// Preserve the system's real UITabBar and its native Liquid Glass,
// selection interactions, accessibility, and tab-switching animations.
// Only its rendered presentation is scaled; SwiftUI's tab layout stays native.
@available(iOS 18, *)
private struct ZagNativeDockTransformBridge: UIViewRepresentable {
    var compact: Bool

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.compact = compact
        view.apply()
    }

    final class Probe: UIView {
        var compact = false
        private weak var tabBar: UITabBar?
        private var animator: UIViewPropertyAnimator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window else { return }
            guard let bar = tabBar ?? findBar(in: window.rootViewController) else { return }
            tabBar = bar
            let target = compact
                ? CGAffineTransform(scaleX: 0.84, y: 0.88)
                : CGAffineTransform.identity
            guard bar.transform != target else { return }
            animator?.stopAnimation(true)
            let animator = UIViewPropertyAnimator(
                duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.34,
                dampingRatio: 0.88
            ) {
                bar.transform = target
            }
            self.animator = animator
            animator.startAnimation()
        }

        private func findBar(in controller: UIViewController?) -> UITabBar? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs.tabBar }
            for child in controller.children {
                if let found = findBar(in: child) { return found }
            }
            if let presented = controller.presentedViewController {
                return findBar(in: presented)
            }
            return nil
        }
    }
}

// A passive observer of actual list scrolling, shared by the main pages.
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

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
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
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
        // Present the real UIKit dock over scrolling content, as the
        // original floating Apple tab bar does. A safeAreaInset incorrectly
        // added another 88pt at the bottom and lifted the dock ~one home
        // indicator above its original position.
        .overlay(alignment: .bottom) {
            if horizontalSizeClass == .compact {
                GeometryReader { geometry in
                    ZagStandaloneNativeDock(
                        selectedTab: selectedTabRawValue,
                        compact: compactDock,
                        tint: UIColor(ZagWideGamutTint.color(hex: themeColorHex)),
                        showsUpdates: updateManager.hasVisibleUpdates,
                        onSelect: { rawValue in
                            selectedTab.wrappedValue = rawValue
                        }
                    )
                    .frame(height: 88)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    // The native bar floats above the home indicator.
                    // Cancel the outer SwiftUI safe-area displacement so
                    // its bottom matches the system tab bar's baseline.
                    .offset(y: max(0, geometry.safeAreaInsets.bottom - 4))
                }
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
        if horizontalSizeClass == .compact {
            TabEnum.view(for: tab)
                // The system TabView still owns navigation. Its managed
                // tab bar is hidden on iPhone so that only one actual
                // UITabBar is visible and touchable.
                .toolbar(.hidden, for: .tabBar)
                .environment(\.zagDockDidScroll, { oldOffset, newOffset in
                    guard selectedTabRawValue == tab.rawValue else { return }
                    trackNativeDockScroll(old: oldOffset, new: newOffset)
                })
        } else {
            // iPad keeps the unmodified native adaptable TabView.
            TabEnum.view(for: tab)
        }
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


// iPhone-only experiment: this is an actual system UITabBar, NOT a
// SwiftUI imitation. Its frame changes size as one unit, allowing UIKit
// to redraw Liquid Glass, the selection capsule, icons and titles itself.
// The original SwiftUI TabView continues owning the actual page navigation.
@available(iOS 18, *)
private struct ZagStandaloneNativeDock: UIViewRepresentable {
    let selectedTab: String
    let compact: Bool
    let tint: UIColor
    let showsUpdates: Bool
    let onSelect: (String) -> Void

    func makeUIView(context: Context) -> DockHost {
        let view = DockHost()
        view.onSelect = onSelect
        return view
    }

    func updateUIView(_ view: DockHost, context: Context) {
        view.onSelect = onSelect
        view.configure(
            selectedTab: selectedTab,
            compact: compact,
            tint: tint,
            showsUpdates: showsUpdates
        )
    }

    final class DockHost: UIView, UITabBarDelegate {
        private let tabBar = UITabBar(frame: .zero)
        private let updatesDot = UIView(frame: .zero)
        private var collapseAnimator: UIViewPropertyAnimator?
        private var isCompact = false
        private var needsFirstLayout = true
        private var lastHostWidth: CGFloat = 0
        private var currentTint: UIColor? = nil

        private static let expandedZImage = makeSourcesImage(size: 25)
        private static let compactZImage = makeSourcesImage(size: 21)

        private static func makeSourcesImage(size: CGFloat) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            let image = renderer.image { _ in
                ZagSourcesTabIcon.image.draw(
                    in: CGRect(x: 0, y: 0, width: size, height: size)
                )
            }
            return image.withRenderingMode(.alwaysTemplate)
        }

        var onSelect: ((String) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            clipsToBounds = false

            tabBar.backgroundColor = .clear
            tabBar.isTranslucent = true
            tabBar.clipsToBounds = false
            tabBar.itemPositioning = .fill
            tabBar.delegate = self

            tabBar.items = TabEnum.defaultTabs.enumerated().map { index, tab in
                let image = tab == .sources
                    ? ZagSourcesTabIcon.image
                    : UIImage(systemName: tab.icon)
                let item = UITabBarItem(
                    title: tab.title,
                    image: image?.withRenderingMode(.alwaysTemplate),
                    selectedImage: nil
                )
                item.tag = index
                item.accessibilityLabel = tab.title
                return item
            }
            addSubview(tabBar)

            updatesDot.backgroundColor = UIColor(
                displayP3Red: 1, green: 0.12, blue: 0.16, alpha: 1
            )
            updatesDot.layer.cornerRadius = 3.5
            updatesDot.isUserInteractionEnabled = false
            updatesDot.isHidden = true
            addSubview(updatesDot)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func configure(
            selectedTab: String,
            compact: Bool,
            tint: UIColor,
            showsUpdates: Bool
        ) {
            tabBar.tintColor = tint
            if currentTint?.isEqual(tint) != true {
                currentTint = tint
                applyItemMetrics(compact: isCompact, tint: tint)
            }
            let index = TabEnum.defaultTabs.firstIndex {
                $0.rawValue == selectedTab
            } ?? 0
            if let items = tabBar.items, items.indices.contains(index),
               tabBar.selectedItem !== items[index] {
                tabBar.selectedItem = items[index]
            }

            updatesDot.isHidden = !showsUpdates

            guard isCompact != compact else {
                // The system can lay out the bar again after tab changes.
                // Do not restart the size animation for selection changes.
                return
            }
            isCompact = compact
            animateSizeChange(tint: tint)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0 else { return }

            // UIKit owns the bar's frame during an active animator.
            // Reposition only when the host really changes width,
            // e.g. rotation or multitasking.
            let widthChanged = abs(bounds.width - lastHostWidth) > 0.5
            if collapseAnimator?.isRunning == true, !widthChanged {
                return
            }
            lastHostWidth = bounds.width
            guard collapseAnimator?.isRunning != true else { return }
            let destination = targetFrame(compact: isCompact)
            if needsFirstLayout || tabBar.frame != destination {
                tabBar.frame = destination
                tabBar.layoutIfNeeded()
                needsFirstLayout = false
            }
            positionUpdatesDot()
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard TabEnum.defaultTabs.indices.contains(item.tag) else { return }
            // This also handles tapping the selected tab: SwiftUI expands
            // the dock even though navigation does not change.
            onSelect?(TabEnum.defaultTabs[item.tag].rawValue)
        }

        private func animateSizeChange(tint: UIColor) {
            guard !needsFirstLayout, bounds.width > 0 else {
                applyItemMetrics(compact: isCompact, tint: tint)
                setNeedsLayout()
                return
            }
            if let previous = collapseAnimator {
                previous.stopAnimation(false)
                previous.finishAnimation(at: .current)
                collapseAnimator = nil
            }

            let destination = targetFrame(compact: isCompact)
            guard tabBar.frame != destination else {
                applyItemMetrics(compact: isCompact, tint: tint)
                positionUpdatesDot()
                return
            }
            let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled
                ? 0
                : 0.38

            // Icons and type become slightly smaller together with the
            // glass. Cross-dissolve UIKit's discrete symbol/font metrics;
            // the capsule itself continues its uninterrupted frame spring.
            UIView.transition(
                with: tabBar,
                duration: duration * 0.65,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent],
                animations: { [weak self] in
                    self?.applyItemMetrics(compact: self?.isCompact ?? false, tint: tint)
                }
            )

            let animator = UIViewPropertyAnimator(
                duration: duration,
                dampingRatio: 0.94
            ) { [weak self] in
                guard let self else { return }
                self.tabBar.frame = destination
                self.tabBar.layoutIfNeeded()
                self.positionUpdatesDot()
            }
            collapseAnimator = animator
            animator.addCompletion { [weak self] _ in
                guard let self else { return }
                self.collapseAnimator = nil
                self.setNeedsLayout()
            }
            animator.startAnimation()
        }

        private func applyItemMetrics(compact: Bool, tint: UIColor) {
            let symbolSize: CGFloat = compact ? 19.0 : 22.0
            let configuration = UIImage.SymbolConfiguration(
                pointSize: symbolSize,
                weight: .medium
            )
            for (index, item) in (tabBar.items ?? []).enumerated() {
                guard TabEnum.defaultTabs.indices.contains(index) else { continue }
                let tab = TabEnum.defaultTabs[index]
                item.image = tab == .sources
                    ? (compact ? Self.compactZImage : Self.expandedZImage)
                    : UIImage(
                        systemName: tab.icon,
                        withConfiguration: configuration
                    )?.withRenderingMode(.alwaysTemplate)
                // Never abbreviate or remove labels in the compact state.
                item.title = tab.title
            }

            // Keep the exact system-defined background / Liquid Glass
            // appearance, only adjusting item typography and theme tint.
            let appearance = (tabBar.standardAppearance.copy()
                as? UITabBarAppearance) ?? UITabBarAppearance()
            let fontSize: CGFloat = compact ? 9.5 : 10.5
            for layout in [
                appearance.stackedLayoutAppearance,
                appearance.inlineLayoutAppearance,
                appearance.compactInlineLayoutAppearance
            ] {
                layout.normal.titleTextAttributes = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .regular)
                ]
                layout.selected.titleTextAttributes = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: tint
                ]
                layout.selected.iconColor = tint
            }
            tabBar.standardAppearance = appearance
            tabBar.scrollEdgeAppearance = appearance
        }

        private func targetFrame(compact: Bool) -> CGRect {
            // The iOS 26+ standalone UITabBar renders its own floating
            // glass capsule *inside* these frames. We change the actual
            // layout rectangle rather than applying a transform.
            // The host itself spans the display width. UIKit's own
            // Liquid Glass optical insets then match the original expanded
            // tab bar (the previous 396pt cap made it noticeably narrower).
            let expandedWidth = min(max(bounds.width, 0), 460)
            // A 10% reduction is visible without forcing UIKit to
            // truncate Discover, Sources, Activity or Devices.
            let width = compact ? expandedWidth * 0.90 : expandedWidth
            let height: CGFloat = compact ? 70 : 78
            return CGRect(
                x: (bounds.width - width) / 2,
                y: bounds.height - height - 2,
                width: width,
                height: height
            )
        }

        private func positionUpdatesDot() {
            let frame = tabBar.frame
            // Apps is the third of five evenly distributed native items.
            // Keep the vivid red indicator as a passive overlay.
            updatesDot.frame = CGRect(
                x: frame.minX + frame.width * 2.5 / 5 + 8.5,
                y: frame.minY + 11,
                width: 7,
                height: 7
            )
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

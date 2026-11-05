import SwiftUI
import UIKit

// Settings → Zag Store → Bottom Dock → Six-Icon Dock (iOS 26, iPhone).
//
// A Liquid Glass dock with the five chosen pages, no labels, and a permanent
// Search action on the right. Search never opens a page: it shows the current
// page's own search bar (its text, mic, scopes and filtering) just above the
// dock. The dock becomes compact while scrolling down (with Shrink on Scroll).
// With the switch off, on iPad and before iOS 26 the system dock is used, and
// every page keeps its native search bar under the title.

enum ZagGlassDockSettings {
	static let enabledKey = "ZagStore.navigation.glassDock"

	static var isSupported: Bool {
		if #available(iOS 26.0, *) { return true }
		return false
	}
}

/// Geometry measured from iOS 26's own dock on iPhone: 62 points tall,
/// 21 points from each side and from the bottom of the screen, with the
/// selection pill inset 4 points.
enum ZagGlassDockMetrics {
	static let height: CGFloat = 62
	static let compactHeight: CGFloat = 52
	static let sideInset: CGFloat = 21
	/// How much narrower each side gets when compact.
	static let compactExtraInset: CGFloat = 26
	static let pillInset: CGFloat = 4
	static let iconSize: CGFloat = 30
	static let compactIconScale: CGFloat = 0.86
	/// The floating search bar: Settings' bottom search height, 10 points
	/// above the dock, or 12 above the keyboard.
	static let searchHeight: CGFloat = 48
	static let searchGap: CGFloat = 10
	static let keyboardGap: CGFloat = 12

	/// The dock's gap above the bottom of the screen: 21 points on iPhones
	/// with a home indicator (as iOS 26's dock), 8 points on the others.
	static func bottomGap(safeBottom: CGFloat) -> CGFloat {
		safeBottom > 0 ? max(8, safeBottom - 13) : 8
	}

	/// The space the dock takes above the bottom safe area.
	static func reserve(safeBottom: CGFloat) -> CGFloat {
		height + bottomGap(safeBottom: safeBottom) - safeBottom
	}

	static func motion(reduceMotion: Bool) -> Animation {
		reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.86)
	}
}

// MARK: - Search coordination

/// Which page's search bar is showing above the dock. Search text, scopes
/// and filtering stay with each page; this only presents them.
final class ZagDockSearch: ObservableObject {
	/// The page whose bar was opened from the dock. Cleared on page change.
	@Published private(set) var openedPage: TabEnum?
	/// Pages showing their bar: opened from the dock, or holding a query.
	@Published private(set) var shownPages: Set<TabEnum> = []
	/// Pages whose main screen is on screen, so their bar can show.
	@Published private(set) var availablePages: Set<TabEnum> = []
	/// Bumped to ask a page to cancel its search (clear the query), as the
	/// native search bar's Cancel button does.
	@Published private(set) var cancelRequests: [TabEnum: Int] = [:]
	@Published private(set) var keyboardVisible = false
	/// The dock's height above the bottom safe area.
	var dockReserve: CGFloat = ZagGlassDockMetrics.reserve(safeBottom: 34) {
		didSet { if dockReserve != oldValue { applyDockInsets() } }
	}
	/// False once the system dock is back: the pages' insets are removed.
	private var reservesDock = true

	private var observers: [NSObjectProtocol] = []

	init() {
		let center = NotificationCenter.default
		observers.append(center.addObserver(
			forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
		) { [weak self] note in
			self?.keyboardFrameWillChange(note)
		})
		observers.append(center.addObserver(
			forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
		) { [weak self] note in
			self?.setKeyboardVisible(false, note: note)
		})
	}

	deinit {
		observers.forEach(NotificationCenter.default.removeObserver)
	}

	/// The dock's Search button: shows the page's bar, or cancels its search.
	func toggle(_ page: TabEnum) {
		if shownPages.contains(page) {
			openedPage = nil
			cancelRequests[page, default: 0] += 1
		} else if availablePages.contains(page) {
			openedPage = page
		}
	}

	/// A different page was chosen: the bar opened on the old one closes.
	/// A page holding a query shows it again when it comes back.
	func pageChanged() {
		if openedPage != nil { openedPage = nil }
	}

	/// Keeps every page's content, bars and pushed screens clear of the
	/// dock. SwiftUI insets stop at each page's navigation stack, so this is
	/// set on the pages' own controllers. With the keyboard up the dock is
	/// behind it, so nothing is reserved.
	func applyDockInsets() {
		guard let tabs = ZagPageSlide.tabBarController() else { return }
		let bottom = reservesDock && !keyboardVisible ? dockReserve : 0
		for page in tabs.viewControllers ?? [] where page.additionalSafeAreaInsets.bottom != bottom {
			page.additionalSafeAreaInsets.bottom = bottom
		}
	}

	/// The system dock is back (the switch was turned off or the width changed).
	func stopReservingDock() {
		reservesDock = false
		applyDockInsets()
	}

	func startReservingDock() {
		reservesDock = true
		applyDockInsets()
	}

	fileprivate func setShown(_ page: TabEnum, _ shown: Bool) {
		if shown != shownPages.contains(page) {
			if shown { shownPages.insert(page) } else { shownPages.remove(page) }
		}
	}

	fileprivate func setAvailable(_ page: TabEnum, _ available: Bool) {
		if available != availablePages.contains(page) {
			if available { availablePages.insert(page) } else { availablePages.remove(page) }
		}
		if !available, openedPage == page { openedPage = nil }
	}

	private func keyboardFrameWillChange(_ note: Notification) {
		guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
		let screen = UIScreen.main.bounds
		// A hardware keyboard shows only a short bar; treat that as hidden.
		setKeyboardVisible(frame.minY < screen.maxY - 1 && frame.height > 120, note: note)
	}

	private func setKeyboardVisible(_ visible: Bool, note: Notification) {
		guard visible != keyboardVisible else { return }
		let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
		withAnimation(.easeOut(duration: max(duration, 0.1))) {
			keyboardVisible = visible
		}
		applyDockInsets()
	}
}

private struct ZagDockSearchKey: EnvironmentKey {
	static let defaultValue: ZagDockSearch? = nil
}

private struct ZagDockPageKey: EnvironmentKey {
	static let defaultValue: TabEnum? = nil
}

extension EnvironmentValues {
	/// Set on every page while the Six-Icon Dock is in use.
	var zagDockSearch: ZagDockSearch? {
		get { self[ZagDockSearchKey.self] }
		set { self[ZagDockSearchKey.self] = newValue }
	}

	/// The dock page this view belongs to.
	var zagDockPage: TabEnum? {
		get { self[ZagDockPageKey.self] }
		set { self[ZagDockPageKey.self] = newValue }
	}
}

// MARK: - A main page's search

/// A page's search scopes, for the bar above the dock (the native bar keeps
/// using the page's own `searchScopes`).
struct ZagSearchScopeOptions {
	let titles: [String]
	let selection: Binding<String>
}

extension View {
	/// A main page's search. With the system dock: the native search bar
	/// under the title with the Zag mic, exactly as before. With the
	/// Six-Icon Dock: the same text, mic and scopes in a bar just above the
	/// dock, shown from its Search button. The page keeps its own state.
	func zagMainPageSearch(
		text: Binding<String>,
		isFocused: FocusState<Bool>.Binding,
		prompt: String,
		activePrompt: String,
		dictationAvailable: Bool,
		startDictation: @escaping () -> Void,
		scopes: ZagSearchScopeOptions? = nil,
		isShownAboveDock: Binding<Bool>? = nil
	) -> some View {
		modifier(ZagMainPageSearch(
			text: text,
			isFocused: isFocused,
			prompt: prompt,
			activePrompt: activePrompt,
			dictationAvailable: dictationAvailable,
			startDictation: startDictation,
			scopes: scopes,
			isShownAboveDock: isShownAboveDock
		))
	}
}

private struct ZagMainPageSearch: ViewModifier {
	let text: Binding<String>
	let isFocused: FocusState<Bool>.Binding
	let prompt: String
	let activePrompt: String
	let dictationAvailable: Bool
	let startDictation: () -> Void
	let scopes: ZagSearchScopeOptions?
	let isShownAboveDock: Binding<Bool>?

	@Environment(\.zagDockSearch) private var dockSearch
	@Environment(\.zagDockPage) private var page

	func body(content: Content) -> some View {
		if let dockSearch, let page {
			content.modifier(ZagSearchAboveDock(
				search: dockSearch,
				page: page,
				text: text,
				prompt: prompt,
				activePrompt: activePrompt,
				dictationAvailable: dictationAvailable,
				startDictation: startDictation,
				scopes: scopes,
				isShownAboveDock: isShownAboveDock
			))
		} else {
			content
				.searchable(text: text, placement: .platform(), prompt: Text(prompt))
				.modifier(ZagRepositorySearchFocusModifier(isFocused: isFocused))
				.background {
					ZagNativeSearchMicInstaller(
						isAvailable: dictationAvailable,
						action: startDictation,
						prompt: prompt,
						activePrompt: activePrompt
					)
					.frame(width: 0, height: 0)
				}
		}
	}
}

private struct ZagSearchAboveDock: ViewModifier {
	@ObservedObject var search: ZagDockSearch
	let page: TabEnum
	let text: Binding<String>
	let prompt: String
	let activePrompt: String
	let dictationAvailable: Bool
	let startDictation: () -> Void
	let scopes: ZagSearchScopeOptions?
	let isShownAboveDock: Binding<Bool>?

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private var shown: Bool {
		search.openedPage == page || !text.wrappedValue.isEmpty
	}

	func body(content: Content) -> some View {
		content
			.safeAreaInset(edge: .bottom, spacing: 0) {
				ZStack {
					if shown {
						bar.transition(barTransition)
					}
				}
			}
			.onAppear {
				search.setAvailable(page, true)
				report(shown)
			}
			.onDisappear { search.setAvailable(page, false) }
			.onChange(of: shown) { report($0) }
			.onChange(of: search.cancelRequests[page] ?? 0) { _ in
				withAnimation(ZagGlassDockMetrics.motion(reduceMotion: reduceMotion)) {
					text.wrappedValue = ""
				}
			}
	}

	private var bar: some View {
		VStack(spacing: 8) {
			if let scopes {
				// On glass, so the scopes stay legible over the page.
				ZagScopeBar(selection: scopes.selection, titles: scopes.titles)
					.frame(height: ZagScopeBar.controlHeight)
					.padding(4)
					.zagSearchGlass()
			}
			ZagCertificatesNativeBottomSearch(
				text: text,
				prompt: prompt,
				activePrompt: activePrompt,
				closesKeyboardOnSearch: true,
				dictationAvailable: dictationAvailable,
				startDictation: startDictation
			)
			.frame(height: ZagGlassDockMetrics.searchHeight)
			.zagSearchGlass()
		}
		.padding(.horizontal, ZagGlassDockMetrics.sideInset)
		.padding(.top, 8)
		.padding(.bottom, search.keyboardVisible ? ZagGlassDockMetrics.keyboardGap : ZagGlassDockMetrics.searchGap)
	}

	private var barTransition: AnyTransition {
		if reduceMotion { return .opacity }
		return .asymmetric(
			insertion: .opacity
				.combined(with: .offset(y: 12))
				.combined(with: .scale(scale: 0.97, anchor: .bottom)),
			removal: .opacity.combined(with: .offset(y: 8))
		)
	}

	private func report(_ shown: Bool) {
		search.setShown(page, shown)
		if let isShownAboveDock, isShownAboveDock.wrappedValue != shown {
			isShownAboveDock.wrappedValue = shown
		}
	}
}

// MARK: - Pages under the dock

extension View {
	/// Marks a dock page and, with the Six-Icon Dock, hides the system dock
	/// and keeps the page's content clear of the new one.
	@ViewBuilder
	func zagGlassDockPage(_ tab: TabEnum, search: ZagDockSearch?) -> some View {
		if #available(iOS 26.0, *), let search {
			modifier(ZagGlassDockPage(tab: tab, search: search))
		} else {
			self
		}
	}
}

@available(iOS 26.0, *)
private struct ZagGlassDockPage: ViewModifier {
	let tab: TabEnum
	@ObservedObject var search: ZagDockSearch

	func body(content: Content) -> some View {
		content
			.environment(\.zagDockSearch, search)
			.environment(\.zagDockPage, tab)
			.toolbarVisibility(.hidden, for: .tabBar)
			// The space for the dock itself: see ZagDockSearch.applyDockInsets.
			.onAppear { search.applyDockInsets() }
	}
}

// MARK: - Compact state

/// Whether the dock is compact. It becomes compact while the page is
/// scrolled down (with Shrink on Scroll on) and returns to full size when
/// scrolling up, at the top, on a tap, on a page change or with Search.
final class ZagGlassDockState: ObservableObject {
	@Published private(set) var compact = false
	private let tracker = ZagDockScrollTracker()

	init() {
		tracker.onCompactChange = { [weak self] compact in
			self?.setCompact(compact)
		}
	}

	func attach() { tracker.attach() }

	func expand() {
		tracker.reset()
		setCompact(false)
	}

	/// After a page change: track the new page's list, at full size.
	func pageChanged() {
		expand()
		DispatchQueue.main.async { [tracker] in tracker.refresh() }
	}

	/// The current page's dock icon tapped again: back to its first screen,
	/// or to the top when already there (as the system dock does).
	func reselect() {
		expand()
		guard let tabs = ZagPageSlide.tabBarController(),
			  let page = tabs.selectedViewController else { return }
		if let navigation = Self.navigation(in: page), navigation.viewControllers.count > 1 {
			navigation.popToRootViewController(animated: true)
		} else if let scrollView = ZagDockScrollTracker.primaryScrollView(in: page.view) {
			let top = CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top)
			scrollView.setContentOffset(top, animated: true)
		}
	}

	private func setCompact(_ compact: Bool) {
		guard compact != self.compact else { return }
		if compact, !(UserDefaults.standard.object(forKey: ZagDockConfiguration.shrinkOnScrollKey) as? Bool ?? false) {
			return
		}
		withAnimation(ZagGlassDockMetrics.motion(reduceMotion: UIAccessibility.isReduceMotionEnabled)) {
			self.compact = compact
		}
	}

	private static func navigation(in controller: UIViewController) -> UINavigationController? {
		if let navigation = controller as? UINavigationController, navigation.view.window != nil {
			return navigation
		}
		for child in controller.children {
			if let found = navigation(in: child) { return found }
		}
		return nil
	}
}

/// Follows the current page's main list. Only scrolling the user drives
/// counts, with a distance threshold in each direction so small direction
/// changes do not flicker, and the bounce past either end is ignored.
private final class ZagDockScrollTracker {
	var onCompactChange: ((Bool) -> Void)?

	private weak var scrollView: UIScrollView?
	private var observation: NSKeyValueObservation?
	private weak var observedWindow: UIWindow?
	/// Where the current run of scrolling in one direction began.
	private var anchor: CGFloat = 0
	private var compact = false

	static let shrinkDistance: CGFloat = 36
	static let expandDistance: CGFloat = 24
	/// A large title collapses over roughly this distance and changes the
	/// list's top inset as it does, so the dock waits until it is past it.
	static let titleCollapseDistance: CGFloat = 60

	func attach(attempts: Int = 10) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			guard let tabs = ZagPageSlide.tabBarController(), let window = tabs.view.window else {
				if attempts > 0 {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.attach(attempts: attempts - 1) }
				}
				return
			}
			if self.observedWindow !== window {
				self.observedWindow = window
				// Every scroll starts with a touch: find the list then, so
				// pushed screens and new pages are followed too.
				window.addGestureRecognizer(ZagTouchDownObserver { [weak self] in self?.refresh() })
			}
			self.refresh()
		}
	}

	func refresh() {
		guard let page = ZagPageSlide.tabBarController()?.selectedViewController,
			  page.view.window != nil else { return }
		let found = Self.primaryScrollView(in: page.view)
		guard found !== scrollView else { return }
		observation = nil
		scrollView = found
		guard let found else { return }
		anchor = found.contentOffset.y
		observation = found.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
			self?.offsetChanged(view)
		}
	}

	func reset() {
		compact = false
		anchor = scrollView?.contentOffset.y ?? 0
	}

	private func offsetChanged(_ view: UIScrollView) {
		let y = view.contentOffset.y
		let top = -view.adjustedContentInset.top
		let bottom = view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height
		// Back at the top (by any means): full size.
		if y <= top + 4 {
			set(false)
			anchor = y
			return
		}
		// Only the user's own scrolling, on pages long enough to scroll.
		guard view.isTracking || view.isDecelerating, bottom - top > 120 else {
			anchor = y
			return
		}
		// The bounce past the end: keep the current size.
		guard y <= bottom else { return }
		if compact {
			if y > anchor {
				anchor = y
			} else if anchor - y > Self.expandDistance {
				set(false)
				anchor = y
			}
		} else {
			if y < anchor {
				anchor = y
			} else if y - anchor > Self.shrinkDistance, y - top > Self.titleCollapseDistance {
				set(true)
				anchor = y
			}
		}
	}

	private func set(_ compact: Bool) {
		guard compact != self.compact else { return }
		self.compact = compact
		onCompactChange?(compact)
	}

	/// The page's main vertical list: the largest scroll view covering most
	/// of the page (carousels and text views are skipped).
	static func primaryScrollView(in root: UIView) -> UIScrollView? {
		let minimum = CGSize(width: root.bounds.width * 0.8, height: root.bounds.height * 0.5)
		var best: UIScrollView?
		var bestArea: CGFloat = 0
		func visit(_ view: UIView) {
			if view.isHidden || view.alpha < 0.01 { return }
			if let scrollView = view as? UIScrollView, !(scrollView is UITextView) {
				let size = scrollView.bounds.size
				if size.width >= minimum.width, size.height >= minimum.height {
					if size.width * size.height > bestArea {
						best = scrollView
						bestArea = size.width * size.height
					}
					return
				}
			}
			for child in view.subviews { visit(child) }
		}
		visit(root)
		return best
	}
}

/// Notes a touch and steps aside: it never recognises, so it never claims,
/// delays or cancels anyone else's touches.
private final class ZagTouchDownObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
	private let touched: () -> Void

	init(_ touched: @escaping () -> Void) {
		self.touched = touched
		super.init(target: nil, action: nil)
		cancelsTouchesInView = false
		delaysTouchesBegan = false
		delaysTouchesEnded = false
		delegate = self
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
		touched()
		state = .failed
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
		true
	}
}

// MARK: - The dock

@available(iOS 26.0, *)
struct ZagGlassDock: View {
	let tabs: [TabEnum]
	let selection: String
	let hasUpdates: Bool
	let hasStoreUpdate: Bool
	let tintHex: String
	let safeBottom: CGFloat
	let select: (TabEnum) -> Void
	@ObservedObject var search: ZagDockSearch
	@ObservedObject var state: ZagGlassDockState

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.colorScheme) private var colorScheme
	@Namespace private var selectionSpace

	private var tint: Color { ZagWideGamutTint.color(hex: tintHex) }
	private var current: TabEnum? { TabEnum(rawValue: selection) }
	private var motion: Animation { ZagGlassDockMetrics.motion(reduceMotion: reduceMotion) }

	/// The system dock's selection pill: a light wash of the label colour.
	private var pillColor: Color {
		colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)
	}

	var body: some View {
		let compact = state.compact
		HStack(spacing: 0) {
			ForEach(tabs, id: \.rawValue) { tab in
				item(tab, compact: compact)
			}
			searchItem(compact: compact)
		}
		.padding(ZagGlassDockMetrics.pillInset)
		.frame(height: compact ? ZagGlassDockMetrics.compactHeight : ZagGlassDockMetrics.height)
		.glassEffect(.regular.interactive(), in: Capsule())
		.padding(.horizontal, ZagGlassDockMetrics.sideInset + (compact ? ZagGlassDockMetrics.compactExtraInset : 0))
		.padding(.bottom, ZagGlassDockMetrics.bottomGap(safeBottom: safeBottom))
		.animation(motion, value: selection)
	}

	private func item(_ tab: TabEnum, compact: Bool) -> some View {
		let selected = tab == current
		return Button {
			tap(tab)
		} label: {
			icon(tab, selected: selected)
				.frame(width: ZagGlassDockMetrics.iconSize, height: ZagGlassDockMetrics.iconSize)
				.scaleEffect(compact ? ZagGlassDockMetrics.compactIconScale : 1)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background {
					if selected {
						Capsule()
							.fill(pillColor)
							.matchedGeometryEffect(id: "selection", in: selectionSpace)
					}
				}
				.contentShape(Capsule())
		}
		.buttonStyle(ZagGlassDockButtonStyle())
		.accessibilityLabel(tab.title)
		.accessibilityAddTraits(selected ? [.isSelected] : [])
		.accessibilityShowsLargeContentViewer {
			Label { Text(tab.title) } icon: { icon(tab, selected: selected) }
		}
	}

	private func searchItem(compact: Bool) -> some View {
		let available = current.map { search.availablePages.contains($0) } ?? false
		let active = current.map { search.shownPages.contains($0) } ?? false
		return Button {
			guard let current else { return }
			withAnimation(motion) {
				state.expand()
				search.toggle(current)
			}
		} label: {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 21, weight: active ? .semibold : .medium))
				.foregroundStyle(active ? tint : Color.primary)
				.frame(width: ZagGlassDockMetrics.iconSize, height: ZagGlassDockMetrics.iconSize)
				.scaleEffect(compact ? ZagGlassDockMetrics.compactIconScale : 1)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.contentShape(Capsule())
		}
		.buttonStyle(ZagGlassDockButtonStyle())
		.disabled(!available)
		.opacity(available ? 1 : 0.35)
		.accessibilityLabel("Search")
		.accessibilityIdentifier("ZagDockSearch")
		.accessibilityValue(active ? "Shown" : "")
		.accessibilityHint(available
			? (active ? "Closes this page's search" : "Shows this page's search")
			: "This page has no search")
		.accessibilityShowsLargeContentViewer {
			Label("Search", systemImage: "magnifyingglass")
		}
	}

	@ViewBuilder
	private func icon(_ tab: TabEnum, selected: Bool) -> some View {
		let color = selected ? tint : Color.primary
		switch tab {
		case .library:
			ZagAppsTabIcon(
				hasUpdates: hasUpdates,
				hasStoreUpdate: hasStoreUpdate,
				isSelected: selected,
				tintHex: tintHex
			)
		case .sources:
			ZagSourcesTabIcon.label.foregroundStyle(color)
		case .discover:
			ZagPrimaryTabIcons.label(for: .discover).foregroundStyle(color)
		case .games:
			ZagPrimaryTabIcons.label(for: .games).foregroundStyle(color)
		case .activity:
			ZagPrimaryTabIcons.label(for: .activity).foregroundStyle(color)
		case .settings:
			ZagPrimaryTabIcons.label(for: .settings).foregroundStyle(color)
		default:
			Image(systemName: tab.icon)
				.font(.system(size: 21, weight: .medium))
				.foregroundStyle(color)
		}
	}

	private func tap(_ tab: TabEnum) {
		if state.compact {
			withAnimation(motion) { state.expand() }
		}
		guard tab != current else {
			state.reselect()
			return
		}
		ZagPageSlide.dockTouched()
		select(tab)
	}
}

/// A light press response on each dock item; the glass reacts on its own.
private struct ZagGlassDockButtonStyle: ButtonStyle {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
			.animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
	}
}

import SwiftUI
import UIKit

// The full-width native scope bar first built for Settings → App Icon,
// shared so Games, Activity, Appearance and Support use the same control.
//
// It is UIKit's own UISearchBar scope (native Liquid Glass, selection
// animation and colours) without the search field or background. UIKit
// insets the scope inside the search bar; the host measures those insets
// and widens the search bar by exactly that much, so the scope spans the
// space SwiftUI gives it: the page's usable content width. No fixed
// offsets, replacement segmented controls or masks.
struct ZagScopeBar: UIViewRepresentable {
	@Binding var selection: String
	var titles: [String]
	/// Selection values, one per title (defaults to the titles).
	var values: [String]? = nil

	/// Height of the visible scope control; frame the bar with it.
	static var controlHeight: CGFloat {
		UISegmentedControl(items: ["Light", "Dark"]).intrinsicContentSize.height
	}

	private var resolvedValues: [String] { values ?? titles }

	func makeCoordinator() -> Coordinator {
		Coordinator(selection: $selection, values: resolvedValues)
	}

	func makeUIView(context: Context) -> ScopeHost {
		let host = ScopeHost(titles: titles)
		host.searchBar.delegate = context.coordinator
		host.searchBar.selectedScopeButtonIndex = resolvedValues.firstIndex(of: selection) ?? 0
		return host
	}

	func updateUIView(_ host: ScopeHost, context: Context) {
		context.coordinator.selection = $selection
		context.coordinator.values = resolvedValues
		if host.searchBar.scopeButtonTitles != titles {
			host.searchBar.scopeButtonTitles = titles
			host.setNeedsLayout()
		}
		let index = resolvedValues.firstIndex(of: selection) ?? 0
		if host.searchBar.selectedScopeButtonIndex != index {
			host.searchBar.selectedScopeButtonIndex = index
		}
	}

	final class Coordinator: NSObject, UISearchBarDelegate {
		var selection: Binding<String>
		var values: [String]

		init(selection: Binding<String>, values: [String]) {
			self.selection = selection
			self.values = values
		}

		func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange index: Int) {
			guard values.indices.contains(index) else { return }
			selection.wrappedValue = values[index]
		}
	}

	final class ScopeHost: UIView {
		let searchBar = UISearchBar(frame: .zero)

		init(titles: [String]) {
			super.init(frame: .zero)
			backgroundColor = .clear
			isOpaque = false

			searchBar.searchBarStyle = .minimal
			searchBar.showsScopeBar = true
			searchBar.scopeButtonTitles = titles
			searchBar.searchTextField.isHidden = true
			searchBar.backgroundImage = UIImage()
			searchBar.scopeBarBackgroundImage = UIImage()
			addSubview(searchBar)
		}

		required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		override func layoutSubviews() {
			super.layoutSubviews()
			guard bounds.width > 0, bounds.height > 0 else { return }

			// UISearchBar lays the scope out in a 76-point canvas.
			let canvasHeight = max(76, searchBar.sizeThatFits(
				CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
			).height)
			searchBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: canvasHeight)
			searchBar.layoutIfNeeded()

			guard let scope = findScope(in: searchBar), scope.bounds.width > 0 else {
				return
			}
			let original = scope.convert(scope.bounds, to: searchBar)
			guard original.minX.isFinite, original.minY.isFinite,
				  original.maxX.isFinite, original.height.isFinite else {
				return
			}

			// Widen the search bar by UIKit's measured insets so the native
			// scope spans these bounds, centred vertically.
			let leading = max(0, original.minX)
			let trailing = max(0, bounds.width - original.maxX)
			searchBar.frame = CGRect(
				x: -leading,
				y: (bounds.height - original.height) / 2 - original.minY,
				width: bounds.width + leading + trailing,
				height: canvasHeight
			)
			searchBar.layoutIfNeeded()
		}

		private func findScope(in view: UIView) -> UISegmentedControl? {
			if let scope = view as? UISegmentedControl { return scope }
			for child in view.subviews {
				if let scope = findScope(in: child) { return scope }
			}
			return nil
		}
	}
}

extension View {
	/// The App Icon page's layout for a ZagScopeBar inside a Form row:
	/// full row width, the control's own height, no row inset or background.
	func zagScopeBarFormRow() -> some View {
		self
			.frame(maxWidth: .infinity)
			.frame(height: ZagScopeBar.controlHeight)
			.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
			.listRowBackground(Color.clear)
	}

	/// Apply to the Section holding a ZagScopeBar row. Together with
	/// `.environment(\.defaultMinListRowHeight, 0)` on the Form (as on
	/// Settings → App Icon), the bar sits the native title → content gap
	/// below its section title. Below it comes the standard section
	/// spacing, or, with `tightBelow`, nothing: then mark the next
	/// section with `zagScopeBarContentSection()`.
	@ViewBuilder
	func zagScopeBarSection(tightBelow: Bool = false) -> some View {
		if #available(iOS 26.0, *) {
			self.listSectionMargins(tightBelow ? .vertical : .top, 0)
		} else {
			self
		}
	}

	/// The section right after a `tightBelow` scope bar: it sits the same
	/// gap below the bar as the bar sits below its section title.
	@ViewBuilder
	func zagScopeBarContentSection() -> some View {
		if #available(iOS 26.0, *) {
			self.listSectionMargins(.top, ZagScopeBar.titleToContentGap)
		} else {
			self
		}
	}

	/// Slides content in from the side of the newly selected tab. It runs
	/// only right after a tab change, never when content scrolls into view,
	/// and not with Reduce Motion.
	func zagTabSlideIn(_ state: ZagTabSlideState) -> some View {
		modifier(ZagTabSlideIn(state: state))
	}
}

extension ZagScopeBar {
	/// iOS 26's gap between a section title and its content (measured on
	/// a native Form: 13.7 pt).
	static let titleToContentGap: CGFloat = 13.7
}

/// Which way tab content slides, and when the tab last changed.
struct ZagTabSlideState: Equatable {
	var forward = true
	var changedAt: Date = .distantPast
}

extension Binding where Value == String {
	/// A selection binding that records the slide direction (by position
	/// in `order`) before the new tab's content appears.
	func zagTabSlide(_ state: Binding<ZagTabSlideState>, order: [String]) -> Binding<String> {
		Binding(
			get: { wrappedValue },
			set: { newValue in
				let oldValue = wrappedValue
				guard newValue != oldValue else { return }
				let from = order.firstIndex(of: oldValue) ?? 0
				let to = order.firstIndex(of: newValue) ?? 0
				state.wrappedValue = ZagTabSlideState(forward: to >= from, changedAt: Date())
				wrappedValue = newValue
			}
		)
	}
}

private struct ZagTabSlideIn: ViewModifier {
	let state: ZagTabSlideState
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var progress: CGFloat = 0

	func body(content: Content) -> some View {
		content
			// One geometry for the whole content, so images that finish
			// loading mid-slide (app icons) move with it.
			.modifier(ZagGeometryGroup())
			.offset(x: progress * (state.forward ? 1 : -1) * 90)
			.opacity(1 - Double(progress))
			.onAppear {
				guard !reduceMotion, Date().timeIntervalSince(state.changedAt) < 0.5 else { return }
				progress = 1
				withAnimation(ZagTabSlideMotion.animation) { progress = 0 }
			}
	}
}

enum ZagTabSlideMotion {
	static let distance: CGFloat = 90
	static let animation = Animation.spring(response: 0.38, dampingFraction: 0.9)
}

private struct ZagGeometryGroup: ViewModifier {
	@ViewBuilder
	func body(content: Content) -> some View {
		if #available(iOS 17.0, *) {
			content.geometryGroup()
		} else {
			content
		}
	}
}

extension View {
	/// The same slide for a native Form row. A Form draws a new row a
	/// moment after SwiftUI creates it and does not play SwiftUI
	/// animations inside rows, so the row's own layer is animated with
	/// Core Animation once the row is on screen.
	func zagTabSlideInRow(_ state: ZagTabSlideState) -> some View {
		background(ZagRowSlideProbe(state: state).allowsHitTesting(false))
	}
}

private struct ZagRowSlideProbe: UIViewRepresentable {
	let state: ZagTabSlideState

	func makeUIView(context: Context) -> Probe {
		let probe = Probe()
		probe.state = state
		return probe
	}

	func updateUIView(_ probe: Probe, context: Context) {
		probe.state = state
		probe.playIfNeeded()
	}

	final class Probe: UIView {
		var state = ZagTabSlideState()
		// The tab change already played. A Form keeps and reuses row views
		// when content returns to an earlier tab, so this is keyed on the
		// change, not on the view being new.
		private var playedChange: Date?

		override func didMoveToWindow() {
			super.didMoveToWindow()
			playIfNeeded()
		}

		func playIfNeeded() {
			guard window != nil, playedChange != state.changedAt,
				  Date().timeIntervalSince(state.changedAt) < 0.5 else { return }
			playedChange = state.changedAt
			guard !UIAccessibility.isReduceMotionEnabled else { return }
			// After this update is committed, so the row shows its new content.
			DispatchQueue.main.async { [weak self] in self?.play() }
		}

		private func play() {
			guard let row = rowContentView() else { return }
			let spring = CASpringAnimation(keyPath: "transform.translation.x")
			spring.fromValue = (state.forward ? 1 : -1) * ZagTabSlideMotion.distance
			spring.toValue = 0
			spring.mass = 1
			spring.stiffness = 273   // response ≈ 0.38 s
			spring.damping = 29.8    // damping fraction ≈ 0.9
			spring.duration = spring.settlingDuration
			let fade = CABasicAnimation(keyPath: "opacity")
			fade.fromValue = 0
			fade.toValue = 1
			fade.duration = 0.3
			fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
			for animation in [spring, fade] as [CAAnimation] {
				animation.fillMode = .backwards
				animation.isRemovedOnCompletion = true
			}
			row.layer.add(spring, forKey: "zagTabSlide")
			row.layer.add(fade, forKey: "zagTabFade")
		}

		/// The content view of the list cell this probe sits in.
		private func rowContentView() -> UIView? {
			var view = superview
			while let current = view {
				if let cell = current as? UICollectionViewCell { return cell.contentView }
				if let cell = current as? UITableViewCell { return cell.contentView }
				view = current.superview
			}
			return nil
		}
	}
}

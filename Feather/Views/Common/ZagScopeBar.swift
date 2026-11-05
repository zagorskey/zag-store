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
	/// below its section title, and the standard section spacing comes
	/// after it.
	@ViewBuilder
	func zagScopeBarSection() -> some View {
		if #available(iOS 26.0, *) {
			self.listSectionMargins(.top, 0)
		} else {
			self
		}
	}
}

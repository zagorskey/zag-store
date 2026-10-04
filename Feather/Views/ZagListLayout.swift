import SwiftUI
import UIKit

/// Canonical compact-list geometry for Zag Store.
///
/// Keep App-Store-style list measurements here so Apps, Sources, repository
/// results and UIKit-backed lists cannot silently drift apart.
enum ZagListLayout {
	static let compactRowHeight: CGFloat = 84
	static let horizontalInset: CGFloat = 20
	static let separatorLeadingInset: CGFloat = 72
	static let pageBottomSpacing: CGFloat = 48
	static let sectionSpacing: CGFloat = 20
	static let actionWidth: CGFloat = 88
	static let actionHeight: CGFloat = 34

	static var separatorHeight: CGFloat {
		1.0 / UIScreen.main.scale
	}
}

private struct ZagCompactRowSeparator: ViewModifier {
	let visible: Bool

	func body(content: Content) -> some View {
		content
			.listRowSeparator(.hidden)
			.overlay(alignment: .bottom) {
				if visible {
					Rectangle()
						.fill(Color(uiColor: .separator))
						.frame(height: ZagListLayout.separatorHeight)
						.padding(.leading, ZagListLayout.separatorLeadingInset)
				}
			}
	}
}

extension View {
	func zagCompactRowSeparator(_ visible: Bool = true) -> some View {
		modifier(ZagCompactRowSeparator(visible: visible))
	}

	func zagPageBottomSpacer() -> some View {
		self
			.frame(height: ZagListLayout.pageBottomSpacing)
			.listRowInsets(EdgeInsets())
			.listRowSeparator(.hidden)
			.listRowBackground(Color.clear)
	}

	func zagSectionSpacer() -> some View {
		self
			.frame(height: ZagListLayout.sectionSpacing)
			.listRowInsets(EdgeInsets())
			.listRowSeparator(.hidden)
			.listRowBackground(Color.clear)
	}
}

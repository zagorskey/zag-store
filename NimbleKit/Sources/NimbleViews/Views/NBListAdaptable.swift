//
//  NBListAdaptable.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI

public struct NBListAdaptable<Content>: View where Content: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	
	private var _content: Content
	private var _transparentBackground: Bool

	public init(
		transparentBackground: Bool = false,
		@ViewBuilder content: () -> Content
	) {
		self._transparentBackground = transparentBackground
		self._content = content()
	}
	
	public var body: some View {
		if horizontalSizeClass == .compact {
			List {
				_content
			}
			.listStyle(.plain)
			.listRowSeparator(.hidden)
			.scrollContentBackground(_transparentBackground ? .hidden : .visible)
			.listRowBackground(_transparentBackground ? Color.clear : nil)
		} else {
			NBGrid {
				_content
			}
		}
	}
}

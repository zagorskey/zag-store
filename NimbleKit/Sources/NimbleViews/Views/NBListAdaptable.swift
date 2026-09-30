//
//  NBListAdaptable.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI

public struct NBListAdaptable<Content>: View where Content: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.colorScheme) private var colorScheme

	private var zagAppStoreSeparator: Color {
		colorScheme == .dark
			? Color(red: 42.0 / 255.0, green: 42.0 / 255.0, blue: 44.0 / 255.0)
			: Color(red: 231.0 / 255.0, green: 231.0 / 255.0, blue: 231.0 / 255.0)
	}
	
	private var _content: Content
	
	public init(@ViewBuilder content: () -> Content) {
		self._content = content()
	}
	
	public var body: some View {
		if horizontalSizeClass == .compact {
			List {
				_content
			}
			.listStyle(.plain)
			.listRowSeparatorTint(zagAppStoreSeparator)
		} else {
			NBGrid {
				_content
			}
		}
	}
}

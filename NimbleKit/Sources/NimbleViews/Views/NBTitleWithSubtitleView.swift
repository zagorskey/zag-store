//
//  FRTitleWithSubtitleView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI

public struct NBTitleWithSubtitleView: View {
	private let _title: String
	private let _subtitle: String
	private var _linelimit: Int? = nil
	
	public init(title: String, subtitle: String, linelimit: Int? = nil) {
		self._title = title
		self._subtitle = subtitle
		self._linelimit = linelimit
	}
	
	public var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(_title)
				.zagContentTitleStyle()
			Text(_subtitle)
				.zagContentSubtitleStyle()
		}
		.padding(.vertical, 2)
		.lineLimit(_linelimit)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}


// MARK: - Standard Zag Store Content Title

public extension View {
	func zagContentTitleStyle() -> some View {
		self
			.font(.system(size: 20, weight: .regular))
			.foregroundStyle(.primary)
	}
}


// MARK: - Standard Zag Store Content Subtitle

public extension View {
	func zagContentSubtitleStyle() -> some View {
		self
			.font(.system(size: 15, weight: .regular))
			.foregroundStyle(Color(uiColor: .secondaryLabel))
	}
}


// MARK: - App Store Pixel Separator

private struct ZagAppStoreRowSeparator: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme
	let leadingInset: CGFloat

	private var color: Color {
		colorScheme == .dark
			? Color(red: 42.0 / 255.0, green: 42.0 / 255.0, blue: 44.0 / 255.0)
			: Color(red: 231.0 / 255.0, green: 231.0 / 255.0, blue: 232.0 / 255.0)
	}

	func body(content: Content) -> some View {
		content
			.listRowSeparator(.hidden)
			.overlay(alignment: .bottom) {
				Rectangle()
					.fill(color)
					.frame(height: 1.0 / UIScreen.main.scale)
					.padding(.leading, leadingInset)
					.allowsHitTesting(false)
			}
	}
}

public extension View {
	func zagAppStoreRowSeparator(leadingInset: CGFloat = 72) -> some View {
		modifier(ZagAppStoreRowSeparator(leadingInset: leadingInset))
	}
}

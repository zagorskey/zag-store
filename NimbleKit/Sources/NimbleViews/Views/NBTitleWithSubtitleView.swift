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
				.font(.subheadline)
				.foregroundColor(.secondary)
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
			.font(.system(size: 17, weight: .regular))
			.foregroundStyle(.primary)
	}
}

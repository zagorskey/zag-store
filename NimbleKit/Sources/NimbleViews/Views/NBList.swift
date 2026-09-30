//
//  NBList.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI

public struct NBList<Content>: View where Content: View {
	public enum NBListType {
		case list
		case form
	}
	
	private var _title: String
	private var _mode: NavigationBarItem.TitleDisplayMode
	private var _type: NBListType
	private var _transparentBackground: Bool
	private var _content: Content
	
	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
		type: NBListType = .form,
		transparentBackground: Bool = false,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._type = type
		self._transparentBackground = transparentBackground
		self._content = content()
	}
	
	public var body: some View {
		Group {
			switch _type {
			case .form:
				Form {
					_content
				}
				.scrollContentBackground(_transparentBackground ? .hidden : .visible)
			case .list:
				List {
					_content
				}
				.scrollContentBackground(_transparentBackground ? .hidden : .visible)
			}
		}
		.navigationTitle(_title)
		.navigationBarTitleDisplayMode(_mode)
	}
}

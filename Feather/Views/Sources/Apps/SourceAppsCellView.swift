//
//  SourceAppsCellView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import Combine
import NukeUI

struct SourceAppsCellView: View {
	@AppStorage("Feather.storeCellAppearance")
	private var _storeCellAppearance: Int = 0

	var source: ASRepository
	var app: ASRepository.App

	var body: some View {
		VStack {
			HStack(spacing: 10) {
				appInformation

				DownloadButtonView(app: app, source: source)
			}

			if
				_storeCellAppearance != 0,
				let desc = app.localizedDescription
			{
				Text(desc)
					.frame(
						maxWidth: .infinity,
						alignment: .leading
					)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.padding(.top, 2)
			}
		}
		.frame(height: ZagListLayout.compactRowHeight)
	}

	private var appInformation: some View {
		HStack(spacing: 10) {
			appIcon

			NBTitleWithSubtitleView(
				title: app.currentName,
				subtitle: Self.appDescription(app: app),
				linelimit: 0
			)
			.frame(
				maxWidth: .infinity,
				alignment: .leading
			)
		}
	}

	@ViewBuilder
	private var appIcon: some View {
		ZStack(alignment: .bottomLeading) {
			ZagRepositoryAppIconView(app: app, size: 62)

			if let sourceIconURL =
				source.currentIconURL
			{
				LazyImage(
					url: sourceIconURL
				) { state in
					if let image = state.image {
						image
							.appIconStyle(
								size: 20,
								isCircle: true,
								background:
									Color(
										uiColor:
											.secondarySystemBackground
									)
							)
							.offset(
								x: 46,
								y: 4
							)
					}
				}
			}
		}
	}

	private var standardIcon: some View {
		Image("App_Unknown")
			.appIconStyle(size: 62)
	}

	static func appDescription(
		app: ASRepository.App
	) -> String {
		let optionalComponents: [String?] = [
			app.currentVersion,
			app.currentDescription
				?? .localized(
					"An awesome application"
				)
		]

		let components: [String] =
			optionalComponents.compactMap {
				value in

				guard
					let trimmed =
						value?
						.trimmingCharacters(
							in:
								.whitespacesAndNewlines
						),
					!trimmed.isEmpty
				else {
					return nil
				}

				return trimmed
			}

		return components.joined(
			separator: " • "
		)
	}
}

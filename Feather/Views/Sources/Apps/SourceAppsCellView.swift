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
import UIKit

struct SourceAppsCellView: View {
	@AppStorage("Feather.storeCellAppearance")
	private var _storeCellAppearance: Int = 0

	@Environment(\.colorScheme) private var colorScheme
	@State private var expandedDescription = false
	var showsRepositoryDetails = false

	var source: ASRepository
	var app: ASRepository.App

	private var uploadDate: String? {
		guard let date = app.currentAppVersion?.date?.date ?? app.currentDate?.date else { return nil }
		let days = Calendar.current.dateComponents(
			[.day],
			from: Calendar.current.startOfDay(for: date),
			to: Calendar.current.startOfDay(for: Date())
		).day ?? 0
		switch days {
		case 0: return .localized("Today")
		case 1: return .localized("Yesterday")
		case 2: return .localized("Two Days Ago")
		case 3: return .localized("Three Days Ago")
		default:
			let formatter = DateFormatter()
			formatter.locale = .current
			formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
			return formatter.string(from: date)
		}
	}

	private var descriptionText: String? {
		let value = app.currentDescription ?? app.localizedDescription
		guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		return value
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				appInformation
				DownloadButtonView(app: app, source: source)
			}
			if showsRepositoryDetails, let descriptionText {
				ZStack(alignment: .bottomTrailing) {
					Text(descriptionText)
						.font(.system(size: 17, weight: .regular))
						.foregroundStyle(.primary)
						.lineLimit(expandedDescription ? nil : 2)
						.frame(maxWidth: .infinity, alignment: .leading)
						.mask {
							if expandedDescription {
								Rectangle()
							} else {
								HStack(spacing: 0) {
									Rectangle()
									LinearGradient(
										stops: [.init(color: .white, location: 0), .init(color: .clear, location: 1)],
										startPoint: .leading, endPoint: .trailing
									).frame(width: 54)
								}
							}
						}
						.padding(.trailing, expandedDescription ? 0 : 42)
					Button(.localized(expandedDescription ? "less" : "more")) {
						withAnimation(.easeInOut(duration: 0.2)) { expandedDescription.toggle() }
					}
					.font(.system(size: 17, weight: .regular))
					.foregroundStyle(colorScheme == .dark ? Color(hex: "#3F8EF7") : Color(hex: "#3A85F8"))
					.buttonStyle(.borderless)
				}
			} else if !showsRepositoryDetails, _storeCellAppearance != 0, let desc = app.localizedDescription {
				Text(desc).font(.subheadline).foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, showsRepositoryDetails ? 14 : 0)
		.frame(minHeight: ZagListLayout.compactRowHeight)
	}

	private var appInformation: some View {
		HStack(spacing: 10) {
			appIcon
			VStack(alignment: .leading, spacing: 3) {
				Text(app.currentName)
					.zagContentTitleStyle()
					.lineLimit(1)
				Text(Self.appDescription(app: app, useDate: showsRepositoryDetails, dateText: uploadDate))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
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
		app: ASRepository.App,
		useDate: Bool = false,
		dateText: String? = nil
	) -> String {
		let optionalComponents: [String?] = [
			app.currentVersion,
			(useDate ? dateText : app.currentDescription)
				?? (useDate ? nil : .localized(
					"An awesome application"
				))
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

//
//  SourcesCellView.swift
//  Zag Store
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import NukeUI
import AltSourceKit

// MARK: - View

struct SourcesCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	var source: AltSource
	var repository: ASRepository?

	private var appCount: Int {
		repository?.apps.count ?? 0
	}

	private var lastUpdatedDate: Date? {
		repository?.apps
			.compactMap { $0.currentDate?.date }
			.max()
	}

	private var lastUpdatedText: String {
		guard let date = lastUpdatedDate else {
			return "Updated: Unknown"
		}

		let calendar = Calendar.current
		let components = calendar.dateComponents([.hour, .minute, .second], from: date)
		let hour = components.hour ?? 0
		let minute = components.minute ?? 0
		let second = components.second ?? 0
		let looksDateOnly = minute == 0 && second == 0 && (hour == 0 || hour == 1)

		if looksDateOnly {
			return "Updated: \(Self.dayFormatter.string(from: date))"
		}

		return "Updated: \(Self.dateFormatter.string(from: date))"
	}

	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_GB")
		formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
		return formatter
	}()

	private static let dayFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_GB")
		formatter.dateFormat = "d MMM yyyy"
		return formatter
	}()

	// MARK: Body

	var body: some View {
		let isRegular = horizontalSizeClass != .compact

		HStack(spacing: 10) {
			repositoryIcon

			VStack(
				alignment: .leading,
				spacing: 3
			) {
				Text(
					source.name ?? .localized("Unknown")
				)
				.zagContentTitleStyle()
				.lineLimit(1)

				Text(lastUpdatedText)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			Spacer(minLength: 8)

			ZagCountBadge(count: appCount)
		}
		.contentShape(Rectangle())
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(
					cornerRadius: 18,
					style: .continuous
				)
				.fill(Color(.quaternarySystemFill))
				: nil
		)
		.swipeActions {
			_actions(for: source)
			_contextActions(for: source)
		}
		.contextMenu {
			_contextActions(for: source)

			Divider()

			_actions(for: source)
		}
	}

	// MARK: Repository Icon

	@ViewBuilder
	private var repositoryIcon: some View {
		if let iconURL = source.iconURL {
			LazyImage(url: iconURL) { state in
				if let image = state.image {
					image.appIconStyle(size: 62)
				} else {
					standardIcon
				}
			}
		} else {
			standardIcon
		}
	}

	private var standardIcon: some View {
		Image("App_Unknown")
			.appIconStyle(size: 62)
	}
}


// MARK: - Extension: Actions

extension SourcesCellView {
	@ViewBuilder
	private func _actions(
		for source: AltSource
	) -> some View {
		Button(
			.localized("Delete"),
			systemImage: "trash",
			role: .destructive
		) {
			// Remove the downloaded repository from Zag Store's
			// live cache first. This immediately causes UpdateManager
			// to recalculate without apps from the deleted source.
			SourcesViewModel.shared.removeSource(source)

			// Then remove the persistent Core Data source.
			Storage.shared.deleteSource(for: source)
		}
	}

	@ViewBuilder
	private func _contextActions(
		for source: AltSource
	) -> some View {
		Button(
			.localized("Copy"),
			systemImage: "doc.on.clipboard"
		) {
			UIPasteboard.general.string =
				source.sourceURL?.absoluteString
		}
	}
}

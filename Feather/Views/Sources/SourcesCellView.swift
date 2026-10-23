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

// A repository's app list can contain tens of thousands of records.
// Build this summary once on a fetch worker, never during SwiftUI body updates
// or while the per-row refresh indicator is animating.
struct ZagSourceRowMetadata: Sendable {
	enum RepositoryKind: Sendable {
		case classic
		case pal
		case mixed

		var title: String {
			switch self {
			case .classic: return "CLASSIC"
			case .pal: return "PAL"
			case .mixed: return "MIXED"
			}
		}
	}

	let appCount: Int
	let kind: RepositoryKind
	let lastUpdated: Date?

	init(repository: ASRepository) {
		appCount = repository.apps.count
		var palCount = 0
		var mostRecent: Date?
		for app in repository.apps {
			if let marketplaceID = app.marketplaceID,
			   !marketplaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				palCount += 1
			}
			if let date = app.currentDate?.date,
			   mostRecent.map({ date > $0 }) ?? true {
				mostRecent = date
			}
		}
		lastUpdated = mostRecent
		if palCount == 0 {
			kind = .classic
		} else if palCount == appCount {
			kind = .pal
		} else {
			kind = .mixed
		}
	}
}

// MARK: - View

struct SourcesCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	var source: AltSource
	var showsSeparator: Bool = true
	var repository: ASRepository?
	var isRefreshing: Bool = false
	var rowMetadata: ZagSourceRowMetadata? = nil

	@State private var refreshDotCount = 0


 	private var appCount: Int {
		rowMetadata?.appCount ?? repository?.apps.count ?? 0
	}

	private var repositoryKind: ZagSourceRowMetadata.RepositoryKind {
		rowMetadata?.kind ?? .classic
	}

	private var lastUpdatedDate: Date? {
		rowMetadata?.lastUpdated
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

		let startOfToday = calendar.startOfDay(for: .now)
		let startOfDate = calendar.startOfDay(for: date)
		let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day

		if let daysAgo, (0...3).contains(daysAgo) {
			let label: String
			switch daysAgo {
			case 0: label = "Today"
			case 1: label = "1 Day Ago"
			case 2: label = "2 Days Ago"
			default: label = "3 Days Ago"
			}
			if looksDateOnly {
				return "Updated: \(label)"
			}
			return "Updated: \(label) at \(Self.timeFormatter.string(from: date))"
		}

		return "Updated: \(Self.dayFormatter.string(from: date))"
	}

	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_GB")
		formatter.dateFormat = "HH:mm"
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
				spacing: 2
			) {
				Text(
					source.name ?? .localized("Unknown")
				)
				.zagContentTitleStyle()
				.lineLimit(1)

				if isRefreshing {
					Text("Updated: Refreshing" + String(repeating: ".", count: refreshDotCount))
						.font(.system(size: 15, weight: .regular))
						.foregroundStyle(Color(uiColor: .secondaryLabel))
						.lineLimit(1)
						.task(id: isRefreshing) {
							refreshDotCount = 0
							while !Task.isCancelled && isRefreshing {
								try? await Task.sleep(for: .milliseconds(380))
								guard !Task.isCancelled && isRefreshing else { break }
								refreshDotCount = (refreshDotCount + 1) % 4
							}
						}
				} else {
					Text(lastUpdatedText)
						.font(.system(size: 15, weight: .regular))
						.foregroundStyle(Color(uiColor: .secondaryLabel))
						.lineLimit(1)
						.contentTransition(.opacity)
				}
			}

			Spacer(minLength: 8)

			VStack(alignment: .trailing, spacing: 7) {
				ZagCountBadge(count: appCount)
				repositoryKindBadge
			}
		}
		.frame(height: isRegular ? nil : ZagListLayout.compactRowHeight)
		.contentShape(Rectangle())
		.overlay(alignment: .bottom) {
			if showsSeparator {
				Rectangle()
					.fill(Color(uiColor: .separator))
					.frame(height: ZagListLayout.separatorHeight)
			}
		}
		.listRowInsets(
			isRegular
				? EdgeInsets()
				: EdgeInsets(top: 0, leading: ZagListLayout.horizontalInset, bottom: 0, trailing: ZagListLayout.horizontalInset)
		)
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

	@ViewBuilder
	private var repositoryKindBadge: some View {
		Text(repositoryKind.title)
			.font(.system(size: 9, weight: .bold, design: .rounded))
			.foregroundStyle(repositoryKind == .pal ? Color.accentColor : Color.secondary)
			.padding(.horizontal, 7)
			.frame(height: 17)
			.background(
				Capsule(style: .continuous)
					.fill(
						repositoryKind == .pal
							? Color.accentColor.opacity(0.14)
							: Color.secondary.opacity(0.12)
					)
			)
			.accessibilityLabel(Text("\(repositoryKind.title) repository"))
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

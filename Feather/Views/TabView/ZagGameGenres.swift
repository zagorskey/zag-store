import SwiftUI
import NukeUI
import NimbleViews

// Games → genre links: a row of pills under the title, like the App Store's
// game categories, each opening a page of the repository games in that
// genre. Genres come from the descriptions repositories supply (keywords),
// as the rest of the Games page does; nothing is fetched.

struct ZagGameGenre: Hashable, Identifiable {
	let name: String
	let symbol: String
	let color: Color
	/// Lower-case words looked for in a game's description.
	let keywords: [String]
	/// A second colour for two-tone symbols.
	var secondColor: Color? = nil

	var id: String { name }

	func matches(_ description: String) -> Bool {
		let text = description.lowercased()
		return keywords.contains { text.contains($0) }
	}

	static let all: [ZagGameGenre] = [
		ZagGameGenre(name: "Action", symbol: "burst.fill", color: .yellow,
					 keywords: ["action", "shooter", "fighting", "hack and slash", "beat 'em up"]),
		ZagGameGenre(name: "Racing", symbol: "flag.checkered", color: .primary,
					 keywords: ["racing", "racer", "drift", "kart"]),
		ZagGameGenre(name: "Strategy", symbol: "point.topleft.down.to.point.bottomright.curvepath", color: .red,
					 keywords: ["strategy", "tactic", "tower defense", "tower defence"], secondColor: .gray),
		ZagGameGenre(name: "Puzzle", symbol: "puzzlepiece.fill", color: .cyan,
					 keywords: ["puzzle", "match-3", "match 3", "brain teaser"]),
		ZagGameGenre(name: "Role-Playing", symbol: "shield.lefthalf.filled", color: .orange,
					 keywords: ["role-playing", "role playing", "rpg", "jrpg", "mmorpg"]),
		ZagGameGenre(name: "Adventure", symbol: "map.fill", color: .gray,
					 keywords: ["adventure", "exploration", "explore"]),
		ZagGameGenre(name: "Simulation", symbol: "shippingbox.fill", color: .brown,
					 keywords: ["simulation", "simulator", "tycoon", "life sim"]),
		ZagGameGenre(name: "Board", symbol: "checkerboard.rectangle", color: .gray,
					 keywords: ["board game", "chess", "checkers", "draughts", "backgammon", "mahjong", "go game"]),
		ZagGameGenre(name: "Sports", symbol: "sportscourt.fill", color: .green,
					 keywords: ["sports", "sport game", "football", "soccer", "basketball", "tennis", "golf", "baseball"]),
		ZagGameGenre(name: "Card", symbol: "suit.club.fill", color: .gray,
					 keywords: ["card game", "solitaire", "deck-building", "deckbuilding", "deck building", "trading card"]),
		ZagGameGenre(name: "Casino", symbol: "suit.spade.fill", color: .red,
					 keywords: ["casino", "slots", "poker", "blackjack", "roulette"]),
		ZagGameGenre(name: "Indie", symbol: "hexagon.fill", color: .green,
					 keywords: ["indie"]),
		ZagGameGenre(name: "Word", symbol: "character.textbox", color: .gray,
					 keywords: ["word game", "crossword", "word puzzle", "wordle", "scrabble", "anagram"]),
		ZagGameGenre(name: "Family", symbol: "person.3.fill", color: .blue,
					 keywords: ["family", "party game"], secondColor: .green),
		ZagGameGenre(name: "Music", symbol: "music.quarternote.3", color: .green,
					 keywords: ["rhythm", "music game", "piano", "guitar"]),
		ZagGameGenre(name: "AR Games", symbol: "arkit", color: .cyan,
					 keywords: ["augmented reality", "arkit"]),
		ZagGameGenre(name: "Casual", symbol: "sparkles", color: .blue,
					 keywords: ["casual", "idle", "clicker", "endless runner"]),
		ZagGameGenre(name: "Kids", symbol: "balloon.2.fill", color: .red,
					 keywords: ["kids", "children", "toddler", "preschool"], secondColor: .purple),
		ZagGameGenre(name: "Trivia", symbol: "questionmark.bubble.fill", color: .orange,
					 keywords: ["trivia", "quiz"])
	]
}

/// The row of genre pills, scrolling sideways under the page title. Only
/// genres with games are shown, each with its count; while the catalogue
/// loads, placeholder pills hold the row's place.
struct ZagGameGenrePills: View {
	/// The page's side margin, so the first pill lines up with the content
	/// while the row itself scrolls to the screen edges.
	let margin: CGFloat
	/// Games per genre name.
	let counts: [String: Int]
	let loading: Bool
	let open: (ZagGameGenre) -> Void

	var body: some View {
		let genres = ZagGameGenre.all.filter { (counts[$0.name] ?? 0) > 0 }
		if !genres.isEmpty {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(genres) { genre in
						let count = counts[genre.name] ?? 0
						Button { open(genre) } label: {
							ZagGameGenrePill(genre: genre, count: count)
						}
						.buttonStyle(.plain)
						.accessibilityLabel("\(genre.name), \(count) \(count == 1 ? "game" : "games")")
						.accessibilityHint("Opens \(genre.name) games")
					}
				}
				.padding(.horizontal, margin)
			}
			.accessibilityElement(children: .contain)
			.accessibilityLabel("Game Genres")
		} else if loading {
			HStack(spacing: 8) {
				ForEach([108, 116, 124, 104], id: \.self) { width in
					Capsule()
						.fill(ZagSkeletonFill.element)
						.frame(width: CGFloat(width), height: 38)
						.zagShimmer()
						.clipShape(Capsule())
				}
			}
			.padding(.horizontal, margin)
			.frame(maxWidth: .infinity, alignment: .leading)
			.clipped()
			.accessibilityHidden(true)
		}
	}

	/// Genre names for each game, from its description.
	static func tags(for games: [SourceAppsView.SourceAppRoute]) -> [String: [String]] {
		var tags: [String: [String]] = [:]
		for entry in games {
			let text = (entry.app.currentDescription ?? entry.app.localizedDescription ?? "").lowercased()
			let names = ZagGameGenre.all.filter { genre in genre.keywords.contains { text.contains($0) } }.map(\.name)
			if !names.isEmpty { tags[entry.id] = names }
		}
		return tags
	}
}

private struct ZagGameGenrePill: View {
	let genre: ZagGameGenre
	let count: Int

	var body: some View {
		HStack(spacing: 7) {
			ZagGameGenreSymbol(genre: genre)
				.font(.system(size: 16, weight: .semibold))
				.frame(minWidth: 20)
			Text(genre.name)
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(.primary)
				.lineLimit(1)
			Text("\(count)")
				.font(.system(size: 14, weight: .medium).monospacedDigit())
				.foregroundStyle(.secondary)
		}
		.padding(.horizontal, 14)
		.frame(height: 38)
		.background(Self.fill, in: Capsule())
		.contentShape(Capsule())
	}

	/// A neutral pill: light grey in light appearance, dark grey in dark.
	static let fill = Color(uiColor: UIColor { traits in
		traits.userInterfaceStyle == .dark
			? UIColor.systemFill
			: UIColor.secondarySystemFill
	})
}

/// A genre's symbol in its colour, or its two colours.
struct ZagGameGenreSymbol: View {
	let genre: ZagGameGenre

	var body: some View {
		if let second = genre.secondColor {
			Image(systemName: genre.symbol)
				.symbolRenderingMode(.palette)
				.foregroundStyle(genre.color, second)
		} else {
			Image(systemName: genre.symbol)
				.foregroundStyle(genre.color)
		}
	}
}

/// A list of games opened from the Games page: a genre, or a section's
/// See All.
struct ZagGameList: Identifiable {
	let title: String
	var genre: ZagGameGenre? = nil
	let games: [SourceAppsView.SourceAppRoute]
	/// What each row shows under the game's name.
	var subtitle: ZagGameRow.Subtitle = .genre

	var id: String { title }
}

/// A full page of games, in rows like the Apps page.
struct ZagGameListPage: View {
	let list: ZagGameList
	/// Genre names per game id, for the rows' subtitles.
	let genreTags: [String: [String]]

	@State private var selectedApp: SourceAppsView.SourceAppRoute?

	var body: some View {
		ScrollView {
			if list.games.isEmpty {
				VStack(spacing: 12) {
					if let genre = list.genre {
						ZagGameGenreSymbol(genre: genre)
							.font(.system(size: 32, weight: .light))
					}
					Text("No \(list.title) Games").font(.headline)
					Text("\(list.title) games from your repositories will appear here.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity)
				.padding(.horizontal, 32)
				.padding(.top, 140)
			} else {
				LazyVStack(spacing: 0) {
					ForEach(list.games, id: \.id) { entry in
						ZagGameRow(
							entry: entry,
							subtitle: list.subtitle,
							genres: genreTags[entry.id] ?? [],
							showsSeparator: entry.id != list.games.last?.id
						) { selectedApp = entry }
					}
				}
				.padding(.horizontal, ZagListLayout.horizontalInset)
				.padding(.top, 4)
				.padding(.bottom, 90)
			}
		}
		.zagWallpaperSurface()
		.navigationTitle(list.title)
		.navigationDestination(
			isPresented: Binding(
				get: { selectedApp != nil },
				set: { if !$0 { selectedApp = nil } }
			)
		) {
			if let selectedApp {
				SourceAppsDetailView(source: selectedApp.source, app: selectedApp.app)
			}
		}
	}
}

/// A game in the layout of an Apps page row: the icon with its repository's
/// badge, name and one line of detail, and the Get / Open button.
struct ZagGameRow: View {
	enum Subtitle {
		/// Genre and version.
		case genre
		/// When it was last updated, and version.
		case updated
		/// Fixed text (for example an emulator's platform).
		case text(String)
	}

	let entry: SourceAppsView.SourceAppRoute
	var subtitle: Subtitle = .genre
	var genres: [String] = []
	var showsSeparator = true
	let open: () -> Void

	var body: some View {
		HStack(spacing: 18) {
			HStack(spacing: 10) {
				icon
				VStack(alignment: .leading, spacing: 3) {
					Text(entry.app.currentName)
						.zagContentTitleStyle()
						.lineLimit(1)
					Text(detail)
						.font(.system(size: 15, weight: .regular))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			DownloadButtonView(app: entry.app, source: entry.source)
		}
		.frame(height: ZagListLayout.compactRowHeight)
		.overlay(alignment: .bottom) {
			if showsSeparator {
				Rectangle()
					.fill(Color(uiColor: .separator))
					.frame(height: ZagListLayout.separatorHeight)
					.padding(.leading, ZagListLayout.separatorLeadingInset)
			}
		}
		.contentShape(Rectangle())
		// A tap gesture rather than a Button, so the Get button keeps its
		// own taps, as on the Apps page.
		.onTapGesture(perform: open)
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityAction(named: Text("Show Details"), open)
	}

	private var icon: some View {
		ZStack(alignment: .bottomLeading) {
			ZagRepositoryAppIconView(app: entry.app, size: 62)
			if let url = entry.source.currentIconURL {
				LazyImage(url: url) { state in
					if let image = state.image {
						image
							.appIconStyle(
								size: 20,
								isCircle: true,
								background: Color(uiColor: .secondarySystemBackground)
							)
							.offset(x: 46, y: 4)
					}
				}
				.accessibilityHidden(true)
			}
		}
	}

	private var detail: String {
		let version = entry.app.currentVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
		let first: String?
		switch subtitle {
		case .genre: first = genres.first
		case .updated: first = ZagGameRow.dayText(Self.updatedDate(entry))
		case .text(let text): first = text
		}
		let parts = [first, version].compactMap { $0 }.filter { !$0.isEmpty }
		return parts.isEmpty ? (entry.source.name ?? "Game") : parts.joined(separator: " • ")
	}

	/// The date of the game's latest version, if the repository gives one.
	static func updatedDate(_ entry: SourceAppsView.SourceAppRoute) -> Date? {
		entry.app.currentAppVersion?.date?.date ?? entry.app.currentDate?.date
	}

	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
		return formatter
	}()

	/// "Today", "Yesterday", "3 Days Ago" or a date, as on the Apps page.
	static func dayText(_ date: Date?) -> String? {
		guard let date else { return nil }
		let calendar = Calendar.current
		let days = calendar.dateComponents(
			[.day],
			from: calendar.startOfDay(for: date),
			to: calendar.startOfDay(for: Date())
		).day ?? 0
		switch days {
		case ...0: return "Today"
		case 1: return "Yesterday"
		case 2...6: return "\(days) Days Ago"
		default: return dateFormatter.string(from: date)
		}
	}
}

/// A section of games scrolling sideways in columns of three rows, like the
/// App Store's game shelves, with a See All link.
struct ZagGameShelf: View {
	let title: String
	var genre: ZagGameGenre? = nil
	let games: [SourceAppsView.SourceAppRoute]
	var subtitle: ZagGameRow.Subtitle = .genre
	let genreTags: [String: [String]]
	/// The page's side margin, for the columns.
	let margin: CGFloat
	let open: (SourceAppsView.SourceAppRoute) -> Void
	let seeAll: () -> Void

	/// How many games a shelf shows before See All.
	static let limit = 12

	/// The shelf's own width (the page's), measured.
	@State private var width: CGFloat = 0

	var body: some View {
		let shown = Array(games.prefix(Self.limit))
		let columns = stride(from: 0, to: shown.count, by: 3).map { Array(shown[$0..<min($0 + 3, shown.count)]) }
		// One column fills the width less a glimpse of the next.
		let columnWidth = min(max(width - margin * 2 - 28, 260), 420)

		VStack(alignment: .leading, spacing: 4) {
			Button(action: seeAll) {
				HStack(spacing: 8) {
					if let genre {
						ZagGameGenreSymbol(genre: genre)
							.font(.system(size: 17, weight: .semibold))
					}
					Text(title)
						.font(.system(size: 20, weight: .semibold))
						.foregroundStyle(.primary)
					Spacer(minLength: 8)
					Text("See All")
						.font(.system(size: 17, weight: .regular))
						.foregroundStyle(.tint)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, margin)
			.accessibilityLabel("\(title), See All")

			ScrollView(.horizontal, showsIndicators: false) {
				LazyHStack(alignment: .top, spacing: 14) {
					ForEach(columns.indices, id: \.self) { index in
						let column = columns[index]
						VStack(spacing: 0) {
							ForEach(column, id: \.id) { entry in
								ZagGameRow(
									entry: entry,
									subtitle: subtitle,
									genres: zagShelfGenres(entry),
									showsSeparator: entry.id != column.last?.id
								) { open(entry) }
							}
						}
						.frame(width: columnWidth, alignment: .top)
					}
				}
				.zagScrollTargetLayout()
				.padding(.horizontal, margin)
			}
			.zagViewAlignedScrolling()
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.background {
			GeometryReader { proxy in
				Color.clear
					.onAppear { width = proxy.size.width }
					.onChange(of: proxy.size.width) { width = $0 }
			}
		}
	}

	/// On a genre's shelf, name the game's other genre if it has one.
	private func zagShelfGenres(_ entry: SourceAppsView.SourceAppRoute) -> [String] {
		let tags = genreTags[entry.id] ?? []
		guard let genre else { return tags }
		let others = tags.filter { $0 != genre.name }
		return others.isEmpty ? tags : others
	}
}

private extension View {
	/// Columns settle at the leading margin after a swipe (iOS 17 and later).
	@ViewBuilder
	func zagViewAlignedScrolling() -> some View {
		if #available(iOS 17.0, *) {
			scrollTargetBehavior(.viewAligned)
		} else {
			self
		}
	}

	@ViewBuilder
	func zagScrollTargetLayout() -> some View {
		if #available(iOS 17.0, *) {
			scrollTargetLayout()
		} else {
			self
		}
	}
}

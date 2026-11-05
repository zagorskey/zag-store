import SwiftUI

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

/// The row of genre pills, scrolling sideways under the page title.
struct ZagGameGenrePills: View {
	/// The page's side margin, so the first pill lines up with the content
	/// while the row itself scrolls to the screen edges.
	let margin: CGFloat
	let open: (ZagGameGenre) -> Void

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(ZagGameGenre.all) { genre in
					Button { open(genre) } label: {
						ZagGameGenrePill(genre: genre)
					}
					.buttonStyle(.plain)
					.accessibilityLabel(genre.name)
					.accessibilityHint("Opens \(genre.name) games")
				}
			}
			.padding(.horizontal, margin)
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Game Genres")
	}
}

private struct ZagGameGenrePill: View {
	let genre: ZagGameGenre

	var body: some View {
		HStack(spacing: 7) {
			ZagGameGenreSymbol(genre: genre)
				.font(.system(size: 16, weight: .semibold))
				.frame(minWidth: 20)
			Text(genre.name)
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(.primary)
				.lineLimit(1)
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
private struct ZagGameGenreSymbol: View {
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

/// One genre's games from the loaded repositories.
struct ZagGameGenrePage: View {
	let genre: ZagGameGenre
	let games: [SourceAppsView.SourceAppRoute]

	@State private var selectedApp: SourceAppsView.SourceAppRoute?

	var body: some View {
		ScrollView {
			if games.isEmpty {
				VStack(spacing: 12) {
					ZagGameGenreSymbol(genre: genre)
						.font(.system(size: 32, weight: .light))
					Text("No \(genre.name) Games").font(.headline)
					Text("\(genre.name) games from your repositories will appear here.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity)
				.padding(.horizontal, 32)
				.padding(.top, 140)
			} else {
				LazyVStack(spacing: 0) {
					ForEach(games, id: \.id) { entry in
						row(entry)
						if entry.id != games.last?.id {
							Divider().padding(.leading, 86)
						}
					}
				}
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
				.overlay {
					RoundedRectangle(cornerRadius: 22, style: .continuous)
						.strokeBorder(Color.secondary.opacity(0.09), lineWidth: 0.5)
				}
				.padding(.horizontal, 18)
				.padding(.top, 12)
				.padding(.bottom, 90)
			}
		}
		.zagWallpaperSurface()
		.navigationTitle(genre.name)
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

	private func row(_ entry: SourceAppsView.SourceAppRoute) -> some View {
		Button { selectedApp = entry } label: {
			HStack(spacing: 13) {
				ZagRepositoryAppIconView(app: entry.app, size: 62)
				VStack(alignment: .leading, spacing: 4) {
					Text(entry.app.currentName)
						.font(.system(size: 16, weight: .semibold))
						.lineLimit(1)
						.foregroundStyle(.primary)
					Text(entry.source.name ?? "Repository")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Spacer()
				Image(systemName: "chevron.right")
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(.tertiary)
					.padding(.trailing, 3)
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 13)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

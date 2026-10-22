//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import NimbleViews
import NukeUI

enum ZagPageStartupPolicy {
	static let rememberLastPageKey = "zagStore.navigation.rememberLastPage"
	static let defaultStartPageKey = "zagStore.navigation.defaultStartPage"
	static let lastPageKey = "zagStore.navigation.selectedTab"

	static var remembersLastPage: Bool {
		let defaults = UserDefaults.standard
		guard defaults.object(forKey: rememberLastPageKey) != nil else {
			return true
		}
		return defaults.bool(forKey: rememberLastPageKey)
	}

	static var initialTab: TabEnum {
		let defaults = UserDefaults.standard
		let rawValue = remembersLastPage
			? defaults.string(forKey: lastPageKey)
			: defaults.string(forKey: defaultStartPageKey)
		let migrated = rawValue == "home" ? TabEnum.discover.rawValue : rawValue
        let tab = TabEnum(rawValue: migrated ?? TabEnum.sources.rawValue) ?? .sources
        return TabEnum.defaultTabs.contains(tab) ? tab : .sources
	}
}

enum TabEnum: String, CaseIterable, Hashable {
	case discover
	case activity
	case games
	case devices
	case sources
	case library
	case settings
	case certificates
	
	// Stable internal destinations for the five primary tabs.
    var internalURL: URL? { URL(string: "zagstore://\(rawValue == "library" ? "apps" : rawValue)") }

    static func tab(for url: URL) -> TabEnum? {
        guard url.scheme?.lowercased() == "zagstore" else { return nil }
        let destination = (url.host ?? "").lowercased()
        switch destination {
        case "discover", "home": return .discover
        case "sources": return .sources
        case "apps", "library": return .library
        case "activity": return .activity
        case "games": return .games
        case "devices": return .devices
        default: return nil
        }
    }

	var title: String {
		switch self {
		case .discover:		return "Discover"
		case .activity:		return "Activity"
        case .games:          return "Games"
		case .devices:		return "Devices"
		case .sources:     	return .localized("Sources")
		case .library: 		return .localized("Apps")
		case .settings: 	return .localized("Settings")
		case .certificates:	return .localized("Certificates")
		}
	}
	
	var icon: String {
		switch self {
		case .discover:		return "safari.fill"
		case .activity:		return "clock.arrow.circlepath"
        case .games:          return "gamecontroller.fill"
		case .devices:		return "iphone"
		case .sources: 		return "atom"
		case .library: 		return "square.stack.3d.up.fill"
		case .settings: 	return "gearshape.fill"
		case .certificates: return "person.text.rectangle"
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .discover: ZagDiscoverPage()
		case .activity: ZagActivityPage()
        case .games: ZagGamesPage()
		case .devices: NavigationStack { ZagDevicesPage() }
		case .sources: SourcesView()
		case .library: LibraryView()
		case .settings: SettingsView()
		case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.discover,
			.sources,
			.library,
			.games,
			.activity
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return [
			.certificates
		]
	}
}


// Discover v1: index the repositories already loaded by Sources.
// No additional manifest fetches, no synthetic rankings, and stable source identities.
private struct ZagDiscoverPage: View {
    @StateObject private var viewModel = SourcesViewModel.shared
    @State private var searchText = ""
    @State private var showFilters = false
    @State private var showSaved = false
    @State private var selectedRepository = "All"
    @AppStorage("ZagDiscover.savedAppIDs") private var savedAppIDs = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var dictationAvailable = false
    @State private var selectedInterest: String?
    @State private var selectedApp: Entry?
    @State private var indexedEntries: [Entry] = []
    @State private var indexRevision = 0
    @State private var hasBuiltIndex = false
    @State private var indexedSourceSignature = ""
    @State private var displayedRecent: [Entry] = []
    @State private var displayedAcross: [Entry] = []
    @State private var displayedSpotlight: [Entry] = []
    @State private var interestCounts: [String: Int] = [:]
    @FetchRequest(
        entity: AltSource.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
    ) private var sources: FetchedResults<AltSource>

    private typealias Entry = SourceAppsView.SourceAppRoute

    private func probeSystemDictation() {
        guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedInstance")),
              let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        else {
            dictationAvailable = false
            return
        }
        dictationAvailable = controller.responds(to: NSSelectorFromString("startDictation"))
    }

    private func startDictationFromSearchMic() {
        searchFieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
                  cls.responds(to: NSSelectorFromString("sharedInstance")),
                  let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
            else { return }
            let preheat = NSSelectorFromString("preheatIfNecessary")
            if controller.responds(to: preheat) { _ = controller.perform(preheat) }
            let start = NSSelectorFromString("startDictation")
            if controller.responds(to: start) { _ = controller.perform(start) }
        }
    }

    private var savedKeys: Set<String> {
        Set(savedAppIDs.split(separator: "\n").map(String.init))
    }

    private func saveKey(_ entry: Entry) -> String {
        (entry.app.id ?? entry.id).lowercased()
    }

    // Manifests can use different identifiers for versions of the same app.
    // Group visible saved rows by normalized display name, while retaining
    // every existing saved identifier for backwards compatibility.
    private func savedDisplayKey(_ entry: Entry) -> String {
        // Collapse punctuation and whitespace too: "The Piano" and "ThePiano"
        // are the same saved title, despite differing manifest display names.
        let name = entry.app.currentName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalized = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let key = String(String.UnicodeScalarView(normalized))
        return key.isEmpty ? saveKey(entry) : key
    }

    private var uniqueSavedEntries: [Entry] {
        var best: [String: Entry] = [:]
        for entry in indexedEntries where savedKeys.contains(saveKey(entry)) {
            let key = savedDisplayKey(entry)
            if let previous = best[key] {
                if (entry.app.currentDate?.date ?? .distantPast) > (previous.app.currentDate?.date ?? .distantPast) {
                    best[key] = entry
                }
            } else {
                best[key] = entry
            }
        }
        return best.values.sorted {
            $0.app.currentName.localizedStandardCompare($1.app.currentName) == .orderedAscending
        }
    }

    private func toggleSaved(_ entry: Entry) {
        var keys = savedKeys
        let nameKey = savedDisplayKey(entry)
        let matchingKeys = Set(indexedEntries.filter {
            savedDisplayKey($0) == nameKey
        }.map { saveKey($0) })
        if !keys.isDisjoint(with: matchingKeys) {
            keys.subtract(matchingKeys)
        } else {
            keys.insert(saveKey(entry))
        }
        savedAppIDs = keys.sorted().joined(separator: "\n")
    }

    private func surpriseMe() {
        let pool = displayedRecent.isEmpty ? indexedEntries : displayedRecent
        if let entry = pool.randomElement() { selectedApp = entry }
    }

    private var entries: [Entry] { indexedEntries }
    private var recent: [Entry] { displayedRecent }
    private var acrossSources: [Entry] { displayedAcross }
    private var spotlight: [Entry] { displayedSpotlight }

    private func rebuildIndex() {
        // Avoid re-indexing thousands of apps when Discover is revisited.
        // Source counts detect additions, removals and repository refreshes.
        let signature = sources.map { source in
            let key = source.identifier ?? source.sourceURL?.absoluteString ?? source.objectID.uriRepresentation().absoluteString
            let count = viewModel.sources[source]?.apps.count ?? -1
            return key + ":" + String(count)
        }.joined(separator: "|")
        guard !hasBuiltIndex || signature != indexedSourceSignature else { return }
        hasBuiltIndex = true
        indexedSourceSignature = signature
        indexedEntries = sources.flatMap { source in
            guard let repository = viewModel.sources[source] else { return [Entry]() }
            // A storefront needs a bounded preview, not a full inventory of gigantic manifests.
            // Full repository browsing remains available through Sources.
            return repository.apps.prefix(400).map { Entry(source: repository, app: $0) }
        }
        updateCollections()
    }

    // Expensive sorting, deduplication and keyword matching run only when
    // source data or a Discover filter changes, never during body evaluation.
    private func updateCollections() {
        let terms = interests.first { $0.name == selectedInterest }?.terms ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var filtered: [Entry] = []
        var counts: [String: Int] = [:]
        for entry in indexedEntries {
            let name = entry.app.currentName.lowercased()
            let description = (entry.app.currentDescription ?? entry.app.localizedDescription ?? "").lowercased()
            for interest in interests where interest.terms.contains(where: { name.contains($0) || description.contains($0) }) {
                counts[interest.name, default: 0] += 1
            }
            guard selectedRepository == "All" || (entry.source.name ?? "Repository") == selectedRepository else { continue }
            guard terms.isEmpty || terms.contains(where: { name.contains($0) || description.contains($0) }) else { continue }
            guard query.isEmpty || name.contains(query) || description.contains(query) || (entry.app.id?.lowercased().contains(query) ?? false) else { continue }
            filtered.append(entry)
        }
        interestCounts = counts
        let sorted = filtered.filter { $0.app.currentDate?.date != nil }
            .sorted { ($0.app.currentDate?.date ?? .distantPast) > ($1.app.currentDate?.date ?? .distantPast) }
        // Editorial-style variety: prefer distinct repositories in the hero,
        // then fill remaining slots with unique apps. No invented rankings.
        var heroCandidates: [Entry] = []
        var seenApps = Set<String>()
        for entry in sorted {
            guard let id = entry.app.id, !id.isEmpty,
                  let description = entry.app.currentDescription ?? entry.app.localizedDescription,
                  description.count > 40,
                  seenApps.insert(id.lowercased()).inserted else { continue }
            heroCandidates.append(entry)
            if heroCandidates.count >= 80 { break }
        }
        var selectedHeroes: [Entry] = []
        var seenSources = Set<String>()
        for entry in heroCandidates {
            let sourceID = entry.source.id ?? entry.source.name ?? ""
            if seenSources.insert(sourceID).inserted {
                selectedHeroes.append(entry)
                if selectedHeroes.count == 5 { break }
            }
        }
        if selectedHeroes.count < 5 {
            let chosen = Set(selectedHeroes.map { ($0.app.id ?? $0.id).lowercased() })
            for entry in heroCandidates where !chosen.contains((entry.app.id ?? entry.id).lowercased()) {
                selectedHeroes.append(entry)
                if selectedHeroes.count == 5 { break }
            }
        }
        displayedSpotlight = selectedHeroes
        let heroIDs = Set(selectedHeroes.compactMap { $0.app.id?.lowercased() })
        displayedRecent = Array(sorted.filter {
            guard let id = $0.app.id else { return true }
            return !heroIDs.contains(id.lowercased())
        }.prefix(15))
        var grouped: [String: [Entry]] = [:]
        for entry in filtered {
            guard let id = entry.app.id, !id.isEmpty else { continue }
            grouped[id.lowercased(), default: []].append(entry)
        }
        displayedAcross = Array(grouped.values.compactMap { group -> Entry? in
            let uniqueSources = Set(group.map { $0.source.id ?? $0.source.name ?? "" })
            guard uniqueSources.count > 1 else { return nil }
            return group.max { ($0.app.currentDate?.date ?? .distantPast) < ($1.app.currentDate?.date ?? .distantPast) }
        }.sorted { $0.app.currentName.localizedStandardCompare($1.app.currentName) == .orderedAscending }.prefix(12))
    }

    // Interest collections are keyword matches, not repository-provided genres.
    // Only show collections that actually contain matching apps.
    private struct Interest {
        let name: String
        let symbol: String
        let terms: [String]
    }

    private let interests: [Interest] = [
        Interest(name: "Games", symbol: "gamecontroller.fill", terms: ["game", "arcade", "emulator", "retro", "minecraft"]),
        Interest(name: "Entertainment", symbol: "play.rectangle.fill", terms: ["video", "movie", "stream", "music", "player", "youtube"]),
        Interest(name: "Social", symbol: "bubble.left.and.bubble.right.fill", terms: ["social", "chat", "messenger", "instagram", "telegram"]),
        Interest(name: "Utilities", symbol: "wrench.and.screwdriver.fill", terms: ["utility", "tools", "network", "vpn", "file manager"]),
        Interest(name: "Developer", symbol: "chevron.left.forwardslash.chevron.right", terms: ["developer", "terminal", "code editor", "github", "debug"])
    ]

    var body: some View {
        NBNavigationView("Discover") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if entries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("Your Discover Starts Here").font(.headline)
                            Text("Add repositories in Sources to explore their apps.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 65)
                    } else {
                        if !spotlight.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("IN THE SPOTLIGHT")
                                        .font(.caption.weight(.bold))
                                        .tracking(1.4)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Fresh from your sources")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 14) {
                                        ForEach(spotlight, id: \.id) { entry in
                                            Button { selectedApp = entry } label: {
                                                spotlightCard(entry)
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                Button(savedKeys.contains(saveKey(entry)) ? "Remove from Saved" : "Save App",
                                                       systemImage: savedKeys.contains(saveKey(entry)) ? "bookmark.slash" : "bookmark") {
                                                    toggleSaved(entry)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Explore by Interest").font(.title2.bold())
                            Text("Collections based on app names and descriptions")
                                .font(.subheadline).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 10) {
                                    ForEach(interests, id: \.name) { interest in
                                        if (interestCounts[interest.name] ?? 0) > 0 {
                                            Button {
                                                selectedInterest = selectedInterest == interest.name ? nil : interest.name
                                                updateCollections()
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Image(systemName: interest.symbol)
                                                        .foregroundStyle(.tint)
                                                    Text(interest.name).font(.subheadline.weight(.semibold))
                                                    Text("\(interestCounts[interest.name] ?? 0)")
                                                        .font(.caption.monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(.horizontal, 15)
                                                .padding(.vertical, 13)
                                                .background(selectedInterest == interest.name ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12), in: Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        if let selectedInterest {
                            Button {
                                self.selectedInterest = nil
                                updateCollections()
                            } label: {
                                Label("Clear \\(selectedInterest) filter", systemImage: "xmark.circle.fill")
                                    .font(.subheadline)
                            }
                        }
                        rail("Fresh Releases", subtitle: "Recently updated across your repositories", entries: recent)
                        rail("More Places to Get It", subtitle: "Apps available from multiple sources", entries: acrossSources)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your Repositories").font(.title2.bold())
                            Text("Explore collections from sources you've added")
                                .font(.subheadline).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(sources, id: \.objectID) { source in
                                        if let repository = viewModel.sources[source] {
                                            NavigationLink {
                                                SourceAppsView(object: [source], viewModel: viewModel)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    HStack {
                                                        Image(systemName: "square.stack.3d.up.fill")
                                                            .font(.title2)
                                                            .foregroundStyle(.tint)
                                                            .frame(width: 42, height: 42)
                                                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                                                        Spacer()
                                                        Image(systemName: "arrow.up.right")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    Spacer(minLength: 8)
                                                    Text(repository.name ?? source.name ?? "Repository")
                                                        .font(.headline).lineLimit(2)
                                                        .multilineTextAlignment(.leading)
                                                    Text("\(repository.apps.count.formatted()) apps")
                                                        .font(.caption.weight(.medium))
                                                        .foregroundStyle(.secondary)
                                                }
                                                .frame(width: 165, height: 142, alignment: .leading)
                                                .padding(16)
                                                .background(Color.accentColor.opacity(0.065), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                                    .strokeBorder(Color.accentColor.opacity(0.13)))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 90)
            }
            .background {
                NavigationLink(
                    isActive: Binding(
                        get: { selectedApp != nil },
                        set: { if !$0 { selectedApp = nil } }
                    )
                ) {
                    if let selectedApp {
                        SourceAppsDetailView(source: selectedApp.source, app: selectedApp.app)
                    } else {
                        EmptyView()
                    }
                } label: {
                    EmptyView()
                }
                .frame(width: 0, height: 0)
                .opacity(0)
            }
            // Let the tab transition finish before building the storefront preview.
            // Cancels an obsolete build when repository loading changes again.
            .task(id: indexRevision) {
                do {
                    try await Task.sleep(nanoseconds: 450_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                rebuildIndex()
            }
            .onChange(of: searchText) { _ in updateCollections() }
            .onChange(of: viewModel.isFinished) { _ in
                hasBuiltIndex = false
                indexRevision += 1
            }
            .onChange(of: viewModel.sources.count) { _ in indexRevision += 1 }
            .onChange(of: sources.count) { _ in indexRevision += 1 }
            .searchable(text: $searchText, placement: .platform(), prompt: Text("Apps, Games and More"))
            .modifier(ZagRepositorySearchFocusModifier(isFocused: $searchFieldFocused))
            .background {
                ZagNativeSearchMicInstaller(
                    isAvailable: dictationAvailable,
                    action: startDictationFromSearchMic,
                    prompt: "Apps, Games and More",
                    activePrompt: "Apps, Games and More"
                )
                .frame(width: 0, height: 0)
            }
            .onAppear(perform: probeSystemDictation)
            .zagWallpaperSurface()
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showFilters = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Discover Filters")
                    Button(action: surpriseMe) {
                        Image(systemName: "shuffle")
                    }
                    .disabled(indexedEntries.isEmpty)
                    .accessibilityLabel("Surprise Me")
                }
                ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSaved = true } label: {
                        Image(systemName: "bookmark")
                            .font(.system(size: 19, weight: .regular))
                            .frame(width: 24, height: 24)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Saved Apps")
                    ZagProfileToolbarButton()
                        .tint(.primary)
                        .padding(.trailing, -2)
                }
            }
            .sheet(isPresented: $showFilters) {
                NavigationStack {
                    Form {
                        Picker("Repository", selection: $selectedRepository) {
                            Text("All Repositories").tag("All")
                            ForEach(Array(Set(indexedEntries.map { $0.source.name ?? "Repository" })).sorted(), id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        Button("Clear Filters") {
                            selectedRepository = "All"
                            selectedInterest = nil
                            searchText = ""
                            updateCollections()
                        }
                    }
                    .navigationTitle("Discover Filters")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showFilters = false; updateCollections() }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSaved) {
                NavigationStack {
                    List {
                        ForEach(uniqueSavedEntries, id: \.id) { entry in
                            Button {
                                showSaved = false
                                selectedApp = entry
                            } label: {
                                HStack(spacing: 12) {
                                    ZagRepositoryAppIconView(app: entry.app, size: 44)
                                    VStack(alignment: .leading) {
                                        Text(entry.app.currentName).font(.headline)
                                        Text(entry.source.name ?? "Repository")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Remove from Saved", systemImage: "bookmark.slash") {
                                    toggleSaved(entry)
                                }
                            }
                        }
                    }
                    .overlay {
                        if uniqueSavedEntries.isEmpty {
                            Text("No saved apps yet. Long-press an app in Discover to save it.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    .navigationTitle("Saved Apps")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSaved = false }
                        }
                    }
                }
            }
        }
    }

    private func spotlightCard(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZagRepositoryAppIconView(app: entry.app, size: 82)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
            }
            Spacer(minLength: 18)
            Text(entry.source.name ?? "REPOSITORY")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.tint)
                .lineLimit(1)
                .padding(.bottom, 7)
            Text(entry.app.currentName)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.bottom, 7)
            Text(entry.app.currentDescription ?? entry.app.localizedDescription ?? "Explore this app")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(20)
        .frame(width: 292, height: 264, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.accentColor.opacity(0.08),
                    Color.secondary.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.19), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.app.currentName), from \(entry.source.name ?? "repository")")
    }

    @ViewBuilder
    private func rail(_ title: String, subtitle: String, entries: [Entry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(entries, id: \.id) { entry in
                            Button { selectedApp = entry } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        ZagRepositoryAppIconView(app: entry.app, size: 74)
                                        Spacer(minLength: 0)
                                    }
                                    Text(entry.app.currentName)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(entry.source.name ?? "Repository")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(width: 124, height: 148, alignment: .topLeading)
                                .padding(12)
                                .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.09)))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(savedKeys.contains(saveKey(entry)) ? "Remove from Saved" : "Save App",
                                       systemImage: savedKeys.contains(saveKey(entry)) ? "bookmark.slash" : "bookmark") {
                                    toggleSaved(entry)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// Initial dedicated destinations; the existing Apps and RPPairing workflows
// remain untouched while Activity and device registration are developed.
private struct ZagGamesPage: View {
    @StateObject private var sourcesModel = SourcesViewModel.shared
    @State private var selectedApp: SourceAppsView.SourceAppRoute?
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var dictationAvailable = false
    @State private var selectedCategory = "Games"
    @State private var searchScope = "All"
    @State private var indexedEmulators: [SourceAppsView.SourceAppRoute] = []
    @State private var indexedGames: [SourceAppsView.SourceAppRoute] = []
    @State private var indexSignature = ""
    @State private var indexedGameCount = 0
    @State private var indexedEmulatorCount = 0
    @FetchRequest(
        entity: AltSource.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
    ) private var sources: FetchedResults<AltSource>

    // Classify by normalized product identity rather than a description keyword
    // that can describe an emulator as a "video game" application.
    private let emulatorNames = [
        "delta", "retroarch", "ppsspp", "provenance", "flycast",
        "dolphinios", "folium", "ignited", "gamma", "sameboy",
        "mame", "melonds", "inds", "ad boy", "play!",
        "emu4ios", "gearboy", "gearsystem", "gpsphone", "gba4ios", "snes9x", "scummvm"
    ]

    private func probeSystemDictation() {
        guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedInstance")),
              let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        else {
            dictationAvailable = false
            return
        }
        dictationAvailable = controller.responds(to: NSSelectorFromString("startDictation"))
    }

    private func startDictationFromSearchMic() {
        searchFieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type,
                  cls.responds(to: NSSelectorFromString("sharedInstance")),
                  let controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
            else { return }
            let preheat = NSSelectorFromString("preheatIfNecessary")
            if controller.responds(to: preheat) { _ = controller.perform(preheat) }
            let start = NSSelectorFromString("startDictation")
            if controller.responds(to: start) { _ = controller.perform(start) }
        }
    }

    private func normalizedName(_ name: String) -> String {
        name.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func isEmulator(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        return emulatorNames.contains { normalized.hasPrefix(normalizedName($0)) }
    }

    private func isGameDescription(_ description: String) -> Bool {
        let description = description.lowercased()
        return ["mobile game", "video game", "arcade game", "puzzle game",
                "role-playing game", "racing game", "strategy game"].contains {
            description.contains($0)
        }
    }

    // Curated platform families, not claims about the specific IPA build.
    // Version-specific JIT and device compatibility belong in verified metadata.
    private func emulatorPlatform(_ name: String) -> String {
        let key = normalizedName(name)
        if key.hasPrefix("delta") || key.hasPrefix("ignited") { return "Nintendo systems" }
        if key.hasPrefix("retroarch") { return "Multi-system" }
        if key.hasPrefix("provenance") { return "Multi-system" }
        if key.hasPrefix("ppsspp") { return "PlayStation Portable" }
        if key.hasPrefix("dolphinios") { return "GameCube · Wii" }
        if key.hasPrefix("flycast") { return "Dreamcast" }
        if key.hasPrefix("folium") { return "Nintendo systems" }
        if key.hasPrefix("gamma") { return "PlayStation" }
        if key.hasPrefix("sameboy") || key.hasPrefix("gearboy") { return "Game Boy" }
        if key.hasPrefix("gearsystem") { return "Master System · Game Gear" }
        if key.hasPrefix("melonds") || key.hasPrefix("inds") { return "Nintendo DS" }
        if key.hasPrefix("mame") { return "Arcade" }
        if key.hasPrefix("snes9x") { return "Super Nintendo" }
        if key.hasPrefix("gba4ios") || key.hasPrefix("gpsphone") { return "Game Boy Advance" }
        if key.hasPrefix("scummvm") { return "Classic adventure games" }
        if key.hasPrefix("play") { return "PlayStation 2" }
        return "Emulator"
    }

    // Genre labels are derived only from descriptions supplied by repositories.
    private func gameGenre(_ description: String) -> String? {
        let description = description.lowercased()
        let genres: [(String, String)] = [
            ("puzzle", "Puzzle"), ("racing", "Racing"), ("strategy", "Strategy"),
            ("role-playing", "RPG"), ("arcade", "Arcade"), ("adventure", "Adventure"),
            ("simulation", "Simulation"), ("sports", "Sports")
        ]
        return genres.first { description.contains($0.0) }?.1
    }

    private func matchesSearch(_ entry: SourceAppsView.SourceAppRoute) -> Bool {
        entry.app.currentName.localizedCaseInsensitiveContains(searchText)
        || (entry.source.name?.localizedCaseInsensitiveContains(searchText) ?? false)
        || (entry.app.currentDescription?.localizedCaseInsensitiveContains(searchText) ?? false)
        || (entry.app.localizedDescription?.localizedCaseInsensitiveContains(searchText) ?? false)
    }

    private var emulators: [SourceAppsView.SourceAppRoute] {
        guard !searchText.isEmpty else { return indexedEmulators }
        return indexedEmulators.filter {
            matchesSearch($0)
        }
    }

    private var games: [SourceAppsView.SourceAppRoute] {
        guard !searchText.isEmpty else { return indexedGames }
        return indexedGames.filter {
            matchesSearch($0)
        }
    }

    private func rebuildIndexIfNeeded() {
        let signature = sources.map { source in
            let key = source.identifier ?? source.sourceURL?.absoluteString ?? source.objectID.uriRepresentation().absoluteString
            return key + ":" + String(sourcesModel.sources[source]?.apps.count ?? -1)
        }.joined(separator: "|")
        guard signature != indexSignature else { return }
        indexSignature = signature

        var seenEmulators = Set<String>()
        var seenGames = Set<String>()
        var newEmulators: [SourceAppsView.SourceAppRoute] = []
        var newGames: [SourceAppsView.SourceAppRoute] = []

        for source in sources {
            guard let repository = sourcesModel.sources[source] else { continue }
            for app in repository.apps {
                let name = app.currentName
                let key = normalizedName(name)
                if isEmulator(name) {
                    if seenEmulators.insert(key).inserted && newEmulators.count < 60 {
                        newEmulators.append(SourceAppsView.SourceAppRoute(source: repository, app: app))
                    }
                } else if newGames.count < 60
                    && isGameDescription(app.currentDescription ?? app.localizedDescription ?? "")
                    && seenGames.insert(key).inserted {
                    newGames.append(SourceAppsView.SourceAppRoute(source: repository, app: app))
                }
                if newEmulators.count >= 60 && newGames.count >= 60 { break }
            }
        }
        indexedEmulators = newEmulators
        indexedGames = newGames
        indexedEmulatorCount = newEmulators.count
        indexedGameCount = newGames.count
    }

    var body: some View {
        NBNavigationView("Games") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Picker("Gaming Category", selection: $selectedCategory) {
                        Text("Games").tag("Games")
                        Text("Emulators").tag("Emulators")
                    }
                    .pickerStyle(.segmented)
                    .opacity(searchFieldFocused ? 0 : 1)
                    .frame(height: searchFieldFocused ? 0 : nil)
                    .clipped()

                    if !searchFieldFocused && selectedCategory == "Games" && !indexedGames.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Featured")
                                    .font(.title3.weight(.bold))
                                Spacer()
                                Text("From your repositories")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(Array(indexedGames.prefix(8)), id: \.id) { entry in
                                        Button { selectedApp = entry } label: {
                                            VStack(alignment: .leading, spacing: 12) {
                                                HStack(alignment: .center, spacing: 12) {
                                                    ZagRepositoryAppIconView(app: entry.app, size: 76)
                                                    Spacer(minLength: 0)
                                                    Image(systemName: "arrow.up.right")
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer(minLength: 0)
                                                Text(entry.app.currentName)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(2)
                                                Text(entry.source.name ?? "Repository")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            .padding(16)
                                            .frame(width: 200, height: 172, alignment: .leading)
                                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                                    .strokeBorder(Color.secondary.opacity(0.09), lineWidth: 0.5)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .contentMargins(.trailing, 18)
                        }
                    }

                    if searchFieldFocused ? (searchScope == "All" || searchScope == "Emulators") : selectedCategory == "Emulators" {
                    VStack(alignment: .leading, spacing: 10) {
                        ZagSectionHeader(title: "Emulators", count: emulators.count)
                        Text("Explore platforms from your repositories")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if emulators.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "gamecontroller")
                                    .font(.system(size: 35, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text(searchText.isEmpty ? "No emulators indexed yet" : "No matching emulators")
                                    .font(.headline)
                                Text("Add or refresh a repository containing emulators to see them here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(28)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(emulators, id: \.id) { entry in
                                    Button { selectedApp = entry } label: {
                                        HStack(spacing: 13) {
                                            ZagRepositoryAppIconView(app: entry.app, size: 62)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(entry.app.currentName)
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .lineLimit(1)
                                                    .foregroundStyle(.primary)
                                                Text(emulatorPlatform(entry.app.currentName))
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(.tint)
                                                    .padding(.horizontal, 9)
                                                    .padding(.vertical, 4)
                                                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                                                Text(entry.source.name ?? "Repository")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
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
                                    Divider().padding(.leading, 86)
                                }
                            }
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.09), lineWidth: 0.5)
                            }
                        }
                    }

                    }
                    if searchFieldFocused ? (searchScope == "All" || searchScope == "Games") : selectedCategory == "Games" {
                    VStack(alignment: .leading, spacing: 10) {
                        ZagSectionHeader(title: "Games", count: games.count)
                        Text("Discover titles from your repositories")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if games.isEmpty {
                            Text(searchText.isEmpty ? "No games identified in loaded repositories yet." : "No matching games.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(games, id: \.id) { entry in
                                    Button { selectedApp = entry } label: {
                                        HStack(spacing: 13) {
                                            ZagRepositoryAppIconView(app: entry.app, size: 62)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(entry.app.currentName)
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .lineLimit(1)
                                                    .foregroundStyle(.primary)
                                                HStack(spacing: 7) {
                                                    if let genre = gameGenre(entry.app.currentDescription ?? entry.app.localizedDescription ?? "") {
                                                        Text(genre)
                                                            .font(.system(size: 11, weight: .semibold))
                                                            .foregroundStyle(.tint)
                                                            .padding(.horizontal, 9)
                                                            .padding(.vertical, 4)
                                                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                                                    }
                                                    Text(entry.source.name ?? "Repository")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
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
                        }
                    }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 90)
            }
            .zagWallpaperSurface()
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(
                text: $searchText,
                placement: .platform(),
                prompt: Text("Games, Emulators and More")
            )
            .modifier(ZagRepositorySearchFocusModifier(isFocused: $searchFieldFocused))
            .background {
                ZagNativeSearchMicInstaller(
                    isAvailable: dictationAvailable,
                    action: startDictationFromSearchMic,
                    prompt: "Games, Emulators and More",
                    activePrompt: "Games, Emulators and More"
                )
                .frame(width: 0, height: 0)
            }
            .onAppear(perform: probeSystemDictation)
            .compatSearchScopes($searchScope) {
                Text("All").tag("All")
                Text("Games").tag("Games")
                Text("Emulators").tag("Emulators")
            }
            .onAppear(perform: rebuildIndexIfNeeded)
            .onReceive(sourcesModel.objectWillChange) { _ in
                // Defer indexing until the repository model finishes publishing.
                DispatchQueue.main.async { rebuildIndexIfNeeded() }
            }
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
            .toolbar {
                ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                ToolbarItem(placement: .topBarTrailing) { ZagProfileToolbarButton() }
            }
        }
    }
}

private struct ZagActivityPage: View {
    @StateObject private var sourcesModel = SourcesViewModel.shared
    @StateObject private var updateTransactions = ZagUpdateTransactionManager.shared
    @State private var historyFilter = "All"
    @State private var selectedHistoryRecord: ZagUpdateTransactionManager.ActivityRecord?
    @State private var showRepositoryDetails = false
    @State private var historySearchText = ""
    @FetchRequest(
        entity: AltSource.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
    ) private var sources: FetchedResults<AltSource>

    // The transaction manager records milestones separately. Present one
    // outcome per update ID while preserving all underlying history records.
    private var consolidatedHistory: [ZagUpdateTransactionManager.ActivityRecord] {
        // Signing uses a unique operation ID. Update milestones share an
        // identifier, so collapse only adjacent milestones in a short window.
        // This keeps separate updates of the same app visible in History.
        var latestByIdentifier: [String: Date] = [:]
        return updateTransactions.activityHistory.filter { record in
            if record.status == "Signed" { return true }
            let key = record.updateID.lowercased()
            if let latest = latestByIdentifier[key],
               latest.timeIntervalSince(record.timestamp) < 30 * 60 {
                return false
            }
            latestByIdentifier[key] = record.timestamp
            return true
        }
    }

    private var filteredHistory: [ZagUpdateTransactionManager.ActivityRecord] {
        let statusFiltered = consolidatedHistory.filter { historyFilter == "All" || $0.status == historyFilter }
        let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return statusFiltered }
        return statusFiltered.filter { record in
            (record.appName?.localizedCaseInsensitiveContains(query) ?? false)
            || record.updateID.localizedCaseInsensitiveContains(query)
            || (record.detail?.localizedCaseInsensitiveContains(query) ?? false)
            || record.status.localizedCaseInsensitiveContains(query)
        }
    }

    private func milestones(for record: ZagUpdateTransactionManager.ActivityRecord) -> [ZagUpdateTransactionManager.ActivityRecord] {
        updateTransactions.activityHistory
            .filter {
                $0.updateID.caseInsensitiveCompare(record.updateID) == .orderedSame
                && abs($0.timestamp.timeIntervalSince(record.timestamp)) < 30 * 60
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var loadedRepositories: Int {
        sources.reduce(0) { $0 + (sourcesModel.sources[$1] == nil ? 0 : 1) }
    }

    private var loadedApps: Int {
        sources.reduce(0) { $0 + (sourcesModel.sources[$1]?.apps.count ?? 0) }
    }

    private func refreshRepositories() {
        guard !sourcesModel.isRefreshing else { return }
        Task {
            await sourcesModel.fetchSources(sources, refresh: true)
        }
    }

    var body: some View {
        NBNavigationView("Activity") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OVERVIEW")
                            .font(.caption.weight(.bold))
                            .tracking(1.3)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            activityMetric("Repositories", value: "\(loadedRepositories)/\(sources.count)", symbol: "square.stack.3d.up")
                            activityMetric("Indexed Apps", value: loadedApps.formatted(), symbol: "square.grid.2x2")
                        }
                    }

                    if !updateTransactions.stages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("In Progress").font(.title2.bold())
                            Spacer()
                            if !updateTransactions.stages.isEmpty {
                                Text("\(updateTransactions.stages.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        if !updateTransactions.stages.isEmpty {
                            LazyVStack(spacing: 0) {
                                ForEach(updateTransactions.stages.keys.sorted(), id: \.self) { identifier in
                                    if let stage = updateTransactions.stages[identifier] {
                                        HStack(spacing: 13) {
                                            Image(systemName: operationSymbol(stage))
                                                .font(.title3)
                                                .foregroundStyle(operationIsFailure(stage) ? Color.red : Color.accentColor)
                                                .frame(width: 38, height: 38)
                                                .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(stage.title).font(.subheadline.weight(.semibold))
                                                Text(identifier)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                if case .failed(let message) = stage {
                                                    Text(message)
                                                        .font(.caption)
                                                        .foregroundStyle(.red)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                            }
                                            Spacer(minLength: 0)
                                            if operationIsInProgress(stage) {
                                                ProgressView().controlSize(.small)
                                            }
                                        }
                                        .padding(14)
                                    }
                                }
                            }
                            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 20))
                        }
                    }
                    }
                    if !updateTransactions.activityHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("History").font(.title2.bold())
                                Spacer()
                                Text("\(consolidatedHistory.count) operations")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Picker("History Filter", selection: $historyFilter) {
                                Text("All").tag("All")
                                Text("Installed").tag("Installed")
                                Text("Signed").tag("Signed")
                                Text("Prepared").tag("Ready to Install")
                                Text("Failed").tag("Failed")
                            }
                            .pickerStyle(.segmented)
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                TextField("Search activity", text: $historySearchText)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                if !historySearchText.isEmpty {
                                    Button {
                                        historySearchText = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 42)
                            .background(Color.secondary.opacity(0.085), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            LazyVStack(spacing: 0) {
                                ForEach(filteredHistory) { record in
                                    Button {
                                        selectedHistoryRecord = record
                                    } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        ZStack(alignment: .bottomLeading) {
                                            if let iconURL = record.iconURL.flatMap(URL.init(string:)) {
                                                LazyImage(url: iconURL) { state in
                                                    if let image = state.image {
                                                        image.appIconStyle(size: 62)
                                                    } else {
                                                        Image("App_Unknown").appIconStyle(size: 62)
                                                    }
                                                }
                                            } else {
                                                Image("App_Unknown").appIconStyle(size: 62)
                                            }
                                            if let sourceURL = record.sourceIconURL.flatMap(URL.init(string:)) {
                                                LazyImage(url: sourceURL) { state in
                                                    if let image = state.image {
                                                        image.appIconStyle(
                                                            size: 20,
                                                            isCircle: true,
                                                            background: Color(uiColor: .secondarySystemBackground)
                                                        )
                                                        .offset(x: 46, y: 4)
                                                    }
                                                }
                                            }
                                        }
                                        .frame(width: 66, height: 66)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(record.status).font(.subheadline.weight(.semibold))
                                            Text(record.appName ?? record.updateID)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(2)
                                            if record.appName != nil {
                                                Text(record.updateID)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            if let detail = record.detail {
                                                Text(detail)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Text(activityDateLabel(record.timestamp))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(14)
                                    }
                                    .buttonStyle(.plain)
                                    if record.id != filteredHistory.last?.id {
                                        Divider().padding(.leading, 62)
                                    }
                                }
                            }
                            .overlay {
                                if filteredHistory.isEmpty {
                                    Text(historySearchText.isEmpty ? "No \(historyFilter.lowercased()) operations" : "No matching activity")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(24)
                                }
                            }
                            .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showRepositoryDetails.toggle() }
                    } label: {
                        HStack {
                            Label("Repository Activity", systemImage: "square.stack.3d.up")
                            Spacer()
                            Text("\(loadedRepositories)/\(sources.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: showRepositoryDetails ? "chevron.up" : "chevron.down")
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(15)
                        .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    if showRepositoryDetails || sourcesModel.isRefreshing {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Repository Activity").font(.title2.bold())
                            Spacer()
                            if sourcesModel.isRefreshing {
                                ProgressView().controlSize(.small)
                            }
                        }
                        HStack(spacing: 13) {
                            Image(systemName: sourcesModel.isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.arrow.trianglehead.counterclockwise")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sourcesModel.isRefreshing ? "Refreshing repositories" : "Repository catalogue")
                                    .font(.subheadline.weight(.semibold))
                                Text(sourcesModel.isRefreshing ? "Fetching updated source metadata" : "\(loadedRepositories) of \(sources.count) repositories loaded")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        Button(action: refreshRepositories) {
                            Label(sourcesModel.isRefreshing ? "Refreshing…" : "Refresh Repositories",
                                  systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(sourcesModel.isRefreshing || sources.isEmpty)
                    }
                    .padding(17)
                    .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 22))

                    }

                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 90)
            }
            .zagWallpaperSurface()
            .sheet(item: $selectedHistoryRecord) { record in
                NavigationStack {
                    Form {
                        Section {
                            HStack(spacing: 15) {
                                if let iconURL = record.iconURL.flatMap(URL.init(string:)) {
                                    LazyImage(url: iconURL) { state in
                                        if let image = state.image {
                                            image.appIconStyle(size: 70)
                                        } else {
                                            Image("App_Unknown").appIconStyle(size: 70)
                                        }
                                    }
                                } else {
                                    Image("App_Unknown").appIconStyle(size: 70)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.appName ?? record.updateID)
                                        .font(.title3.weight(.semibold))
                                        .lineLimit(2)
                                    Label(record.status, systemImage: record.status == "Failed" ? "xmark.circle.fill" : (record.status == "Installed" ? "checkmark.circle.fill" : (record.status == "Signed" ? "checkmark.seal.fill" : "clock.arrow.circlepath")))
                                        .font(.subheadline)
                                        .foregroundStyle(record.status == "Failed" ? Color.red : Color.accentColor)
                                    Text(activityDateLabel(record.timestamp))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                        }
                        Section("Operation") {
                            LabeledContent("Status", value: record.status)
                            LabeledContent("App", value: record.appName ?? record.updateID)
                            LabeledContent("Identifier", value: record.status == "Signed" ? (record.detail ?? record.updateID) : record.updateID)
                            LabeledContent("Date", value: record.timestamp.formatted(date: .abbreviated, time: .shortened))
                        }
                        Section("Timeline") {
                            ForEach(milestones(for: record)) { milestone in
                                HStack(spacing: 12) {
                                    Image(systemName: milestone.status == "Failed" ? "xmark.circle.fill" : (milestone.status == "Installed" ? "checkmark.circle.fill" : (milestone.status == "Signed" ? "checkmark.seal.fill" : "circle.fill")))
                                        .font(.subheadline)
                                        .foregroundStyle(milestone.status == "Failed" ? Color.red : Color.accentColor)
                                        .frame(width: 20)
                                    Text(milestone.status)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(milestone.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let detail = milestone.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .navigationTitle("Activity Details")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selectedHistoryRecord = nil }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                ToolbarItem(placement: .topBarTrailing) {
                    ZagProfileToolbarButton()
                        .tint(.primary)
                        .padding(.trailing, -2)
                }
            }
        }
    }

    private func activityDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, " + time }
        if calendar.isDateInYesterday(date) { return "Yesterday, " + time }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func operationIsFailure(_ stage: ZagUpdateTransactionManager.Stage) -> Bool {
        if case .failed = stage { return true }
        return false
    }

    private func operationIsInProgress(_ stage: ZagUpdateTransactionManager.Stage) -> Bool {
        switch stage {
        case .downloading, .importing, .signing, .installing: return true
        default: return false
        }
    }

    private func operationSymbol(_ stage: ZagUpdateTransactionManager.Stage) -> String {
        switch stage {
        case .downloading: return "arrow.down.circle"
        case .importing: return "square.and.arrow.down"
        case .signing: return "signature"
        case .readyToInstall: return "checkmark.circle"
        case .installing: return "square.and.arrow.down.on.square"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func activityMetric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.opacity(0.085), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct ZagDevicesPage: View {
    @State private var batteryLevel: Float = -1
    @State private var batteryState: UIDevice.BatteryState = .unknown
    @State private var storageAvailable: Int64?
    @State private var storageTotal: Int64?
    @State private var showTechnicalDetails = false

    private var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafeBytes(of: machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private var storageFraction: Double {
        guard let available = storageAvailable, let total = storageTotal, total > 0 else { return 0 }
        return min(1, max(0, Double(total - available) / Double(total)))
    }

    private var storageDescription: String {
        guard let available = storageAvailable, let total = storageTotal else { return "Unavailable" }
        return "\(ByteCountFormatter.string(fromByteCount: total - available, countStyle: .file)) used of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    private func refreshInformation() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) {
            storageTotal = values.volumeTotalCapacity.map(Int64.init)
            storageAvailable = values.volumeAvailableCapacityForImportantUsage
        }
    }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 18) {
                        Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad.gen2" : "iphone.gen3")
                            .font(.system(size: 48, weight: .ultraLight))
                            .foregroundStyle(.primary)
                            .frame(width: 68, height: 82)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("This Device")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(UIDevice.current.model)
                                .font(.title2.weight(.semibold))
                            Text("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    HStack(spacing: 12) {
                        deviceMetric(
                            "Battery",
                            value: batteryLevel >= 0 ? "\(Int((batteryLevel * 100).rounded()))%" : "—",
                            symbol: "battery.100",
                            caption: batteryState == .charging ? "Charging" : batteryState == .full ? "Fully charged" : "Current level"
                        )
                        deviceMetric(
                            "Storage",
                            value: storageTotal != nil ? "\(Int((storageFraction * 100).rounded()))%" : "—",
                            symbol: "internaldrive",
                            caption: "Used capacity"
                        )
                    }

                    if storageTotal != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Storage").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(storageDescription).font(.caption).foregroundStyle(.secondary)
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.09))
                                    Capsule()
                                        .fill(Color.accentColor.gradient)
                                        .frame(width: geometry.size.width * storageFraction)
                                }
                            }
                            .frame(height: 7)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showTechnicalDetails.toggle()
                        }
                    } label: {
                        HStack {
                            Label("Device Information", systemImage: "info.circle")
                            Spacer()
                            Image(systemName: showTechnicalDetails ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(15)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)

                    if showTechnicalDetails {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DEVICE INFORMATION")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            detailRow("Operating System", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)", symbol: "gear")
                            Divider().padding(.leading, 48)
                            detailRow("Hardware Identifier", value: hardwareIdentifier, symbol: "cpu")
                            Divider().padding(.leading, 48)
                            detailRow("Device Type", value: UIDevice.current.localizedModel, symbol: "iphone")
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("SYSTEM STATUS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            detailRow("Battery", value: batteryLevel >= 0 ? "\(Int((batteryLevel * 100).rounded()))% \(batteryState == .charging ? "· Charging" : batteryState == .full ? "· Fully Charged" : "")" : "Unavailable", symbol: "battery.100")
                            Divider().padding(.leading, 48)
                            detailRow("Storage", value: storageDescription, symbol: "internaldrive")
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Text("Information is read directly from this device. Paired and registered devices will appear here when device management is available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .zagWallpaperSurface()
            .onAppear(perform: refreshInformation)
            .refreshable { refreshInformation() }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
    }

    private func deviceMetric(_ title: String, value: String, symbol: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                Spacer()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func detailRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}


// iOS 16-compatible replacement for ContentUnavailableView.
private struct ZagEmptyDestination: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

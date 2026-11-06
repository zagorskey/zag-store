//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import Combine
import NimbleViews
import NukeUI
import AltSourceKit
import UIKit

enum ZagDockConfiguration {
    static let storageKey = "ZagStore.navigation.dockTabs"
    /// iOS 26: the dock shrinks to the current page's icon while scrolling down.
    static let shrinkOnScrollKey = "ZagStore.navigation.dockShrinksOnScroll"
    static let defaults: [TabEnum] = [.discover, .sources, .library, .games, .activity]
    static let choices: [TabEnum] = [.discover, .sources, .library, .games, .activity, .devices, .settings]

    static var tabs: [TabEnum] {
        guard let saved = UserDefaults.standard.string(forKey: storageKey) else { return defaults }
        let values = saved.split(separator: ",").compactMap { TabEnum(rawValue: String($0)) }
        let unique = values.reduce(into: [TabEnum]()) { result, tab in
            if choices.contains(tab) && !result.contains(tab) && result.count < 5 { result.append(tab) }
        }
        return unique.isEmpty ? defaults : unique
    }

    static func save(_ tabs: [TabEnum]) {
        let valid = tabs.filter { choices.contains($0) }
        guard !valid.isEmpty, valid.count <= 5, Set(valid).count == valid.count else { return }
        UserDefaults.standard.set(valid.map(\.rawValue).joined(separator: ","), forKey: storageKey)
        reconcileNavigation()
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        reconcileNavigation()
    }

    static func reconcileNavigation() {
        let defaults = UserDefaults.standard
        let allowed = tabs
        let fallback = allowed.first?.rawValue ?? TabEnum.discover.rawValue
        for key in [ZagPageStartupPolicy.defaultStartPageKey, ZagPageStartupPolicy.lastPageKey] {
            guard let stored = defaults.string(forKey: key) else { continue }
            let normalized = stored == "home" ? TabEnum.discover.rawValue : stored
            if !allowed.contains(where: { $0.rawValue == normalized }) {
                defaults.set(fallback, forKey: key)
            }
        }
    }
}

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
        return ZagDockConfiguration.tabs.contains(tab) ? tab : (ZagDockConfiguration.tabs.first ?? .discover)
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
        case "settings": return .settings
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
	
	static var defaultTabs: [TabEnum] { ZagDockConfiguration.tabs }
	
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
private struct ZagFeaturedArtworkCandidate: Sendable {
    let index: Int
    let bundleID: String?
    let name: String
    let screenshots: [URL]
}

// The Games catalogue is read-only. Build its bounded storefront selection
// off the main actor, then publish only the small finished index to SwiftUI.
// Repository values and app routes are Sendable; Core Data objects never
// cross into the worker.
private struct ZagGamesIndexSnapshot: Sendable {
    let emulators: [SourceAppsView.SourceAppRoute]
    let games: [SourceAppsView.SourceAppRoute]
    let featuredCandidates: [SourceAppsView.SourceAppRoute]
    /// Every bundle ID in the repositories, for Apple's catalogue check.
    let bundleIDs: [String]
}

private enum ZagGamesIndexBuilder {
    private static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let emulatorPrefixes: [String] = [
        "delta", "retroarch", "ppsspp", "provenance", "flycast",
        "dolphinios", "folium", "ignited", "gamma", "sameboy",
        "mame", "melonds", "inds", "ad boy", "play!",
        "emu4ios", "gearboy", "gearsystem", "gpsphone",
        "gba4ios", "snes9x", "scummvm"
    ].map { normalizedName($0) }

    /// The most games and emulators the page indexes (the whole catalogue
    /// is scanned; this only bounds memory on huge repositories).
    static let gameLimit = 5000
    static let emulatorLimit = 300

    /// Phrases that describe a game. Matched anywhere in the description.
    private static let gamePhrases = [
        "mobile game", "video game", "arcade game", "puzzle game", "action game",
        "adventure game", "role-playing", "racing game", "strategy game",
        "simulation game", "sports game", "card game", "board game", "word game",
        "trivia game", "casual game", "indie game", "survival game", "horror game",
        "fighting game", "shooter game", "sandbox game", "idle game", "party game",
        "this game", "the game", "a game", "free game", "game for", "game where",
        "battle royale", "open world", "open-world", "single-player", "single player",
        "co-op", "play with friends", "play online", "boss battle", "boss fight",
        "hack and slash", "tower defense", "tower defence", "match-3", "match 3",
        "endless runner", "in-game", "game mode", "high score", "levels to"
    ]

    /// Single words that only games use.
    private static let gameWords: Set<String> = [
        "game", "games", "gameplay", "multiplayer", "roguelike", "roguelite",
        "metroidvania", "platformer", "mmorpg", "rpg", "jrpg", "pvp", "pve",
        "shooter", "arcade", "gamer", "gamers"
    ]

    /// Bundle ID prefixes of game publishers.
    private static let gamePublishers = [
        "com.supercell.", "com.rockstargames.", "com.mojang.", "com.ea.", "com.gameloft.",
        "com.king.", "com.tencent.ig", "com.tencent.smoba", "com.activision.", "com.mihoyo.",
        "com.hoyoverse.", "com.cognosphere.", "com.netease.", "com.innersloth.", "com.kiloo.",
        "com.halfbrick.", "com.rovio.", "com.zynga.", "com.nintendo.", "com.square-enix.",
        "com.squareenix.", "com.bandainamcoent.", "com.sega.", "com.ubisoft.", "com.epicgames.",
        "com.roblox.", "com.playrix.", "com.scopely.", "com.netmarble.", "com.nexon.",
        "com.garena.", "com.mobile.legends", "com.dts.freefire", "com.pubg.", "com.krafton.",
        "com.ninjakiwi.", "com.kabam.", "com.glu.", "com.nianticlabs.", "com.fingersoft.",
        "com.ketchapp.", "com.voodoo.", "com.miniclip.", "com.outfit7.", "com.imangi.",
        "com.noodlecake.", "com.devolver.", "com.chucklefish.", "com.bethsoft.", "com.blizzard.",
        "com.riotgames.", "com.yostar.", "com.nekki.", "com.feralinteractive.", "com.lilithgames.",
        "com.funplus.", "com.moonactive.", "com.dreamgames.", "com.playtika.", "com.bigfishgames.",
        "com.mediocre.", "com.ustwo.", "com.thatgamecompany.", "com.annapurna", "com.crazylabs.",
        "com.saygames.", "com.lionstudios.", "com.tapblaze.", "com.firaxis.", "com.2k.",
        "com.take2games.", "com.capcom.", "com.konami.", "com.levelinfinite.", "com.proximabeta."
    ]

    /// Categories that are clearly not games, so their game-like wording
    /// (a chat app "for gamers") is not enough.
    private static let nonGameCategories: Set<String> = [
        "social", "utilities", "utility", "productivity", "photo", "photo & video",
        "video", "music", "developer", "developer tools", "tweaks", "tweaked",
        "entertainment", "education", "business", "finance", "lifestyle",
        "navigation", "news", "health", "reference", "shopping", "travel", "weather"
    ]

    static func isGame(_ app: ASRepository.App, catalogue: [String: [String]] = [:]) -> Bool {
        if let id = app.id?.lowercased(), catalogue[id] != nil { return true }
        let category = app.category?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        if category.contains("game") { return true }

        let bundle = app.id?.lowercased() ?? ""
        if gamePublishers.contains(where: { bundle.hasPrefix($0) }) { return true }
        if nonGameCategories.contains(category) { return false }
        // A "game" part in the bundle ID, as in com.studio.game.title.
        if bundle.split(separator: ".").dropFirst().contains(where: { $0.hasSuffix("game") || $0.hasSuffix("games") }) {
            return true
        }

        var description = (app.currentDescription ?? app.localizedDescription ?? "").lowercased()
        guard !description.isEmpty else { return false }
        // Phrases that mention games without being one.
        for phrase in ["game changer", "game-changer", "game center", "gamecenter", "game controller support"] {
            description = description.replacingOccurrences(of: phrase, with: " ")
        }
        if gamePhrases.contains(where: { description.contains($0) }) { return true }
        let words = description.split(whereSeparator: { !$0.isLetter })
        return words.contains { gameWords.contains(String($0)) }
    }

    static func build(_ repositories: [ASRepository], catalogue: [String: [String]]) -> ZagGamesIndexSnapshot? {
        var bundleIDs: [String] = []
        var seenEmulators = Set<String>()
        var seenGames = Set<String>()
        var newEmulators: [SourceAppsView.SourceAppRoute] = []
        var newGames: [SourceAppsView.SourceAppRoute] = []
        var artworkCandidates: [SourceAppsView.SourceAppRoute] = []
        var titleCandidates: [SourceAppsView.SourceAppRoute] = []
        var seenArtwork = Set<String>()
        var artworkCountBySource: [String: Int] = [:]

        for repository in repositories {
            guard !Task.isCancelled else { return nil }
            for (index, app) in repository.apps.enumerated() {
                if index % 256 == 0 && Task.isCancelled { return nil }

                if let id = app.id, !id.isEmpty { bundleIDs.append(id) }
                let name = app.currentName
                let key = normalizedName(name)
                if emulatorPrefixes.contains(where: { key.hasPrefix($0) }) {
                    if newEmulators.count < emulatorLimit && seenEmulators.insert(key).inserted {
                        newEmulators.append(.init(source: repository, app: app))
                    }
                    continue
                }

                guard isGame(app, catalogue: catalogue) else { continue }

                if newGames.count < gameLimit && seenGames.insert(key).inserted {
                    newGames.append(.init(source: repository, app: app))
                }

                // Keep checking the whole catalog for genuine, varied artwork
                // without creating an unbounded collection of candidates.
                let sourceKey = repository.id ?? repository.name ?? "Repository"
                if seenArtwork.insert(sourceKey + "::" + key).inserted {
                    let entry = SourceAppsView.SourceAppRoute(source: repository, app: app)
                    if !app.currentScreenshotURLs.isEmpty {
                        if artworkCandidates.count < 72 &&
                           (artworkCountBySource[sourceKey] ?? 0) < 18 {
                            artworkCandidates.append(entry)
                            artworkCountBySource[sourceKey, default: 0] += 1
                        }
                    } else if titleCandidates.count < 48 {
                        titleCandidates.append(entry)
                    }
                }
            }
        }

        var featured: [SourceAppsView.SourceAppRoute] = []
        var featuredSources = Set<String>()
        var featuredIDs = Set<String>()
        for entry in artworkCandidates {
            let source = entry.source.id ?? entry.source.name ?? "Repository"
            guard featuredSources.insert(source).inserted else { continue }
            featured.append(entry)
            featuredIDs.insert(entry.id)
            if featured.count == 96 { break }
        }
        for entry in artworkCandidates where featured.count < 96 {
            guard featuredIDs.insert(entry.id).inserted else { continue }
            featured.append(entry)
        }
        for entry in titleCandidates where featured.count < 96 {
            guard featuredIDs.insert(entry.id).inserted else { continue }
            featured.append(entry)
        }
        return ZagGamesIndexSnapshot(
            emulators: newEmulators,
            games: newGames,
            featuredCandidates: featured,
            bundleIDs: bundleIDs
        )
    }
}

/// A Featured card's app icon: the repository's icon, or, when the repository
/// has none or it fails to load, the app's icon from Apple's catalogue (the
/// same lookup, and cache, as the card's artwork).
private struct ZagCatalogueBackedIcon: View {
    let app: ASRepository.App
    let size: CGFloat

    @State private var catalogueIcon: URL?
    @State private var repositoryIconFailed = false

    var body: some View {
        if let catalogueIcon {
            LazyImage(url: catalogueIcon) { state in
                if let image = state.image {
                    image.appIconStyle(size: size)
                } else {
                    Image("App_Unknown").appIconStyle(size: size)
                }
            }
        } else if let url = app.iconURL, !repositoryIconFailed {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.appIconStyle(size: size)
                } else {
                    Image("App_Unknown").appIconStyle(size: size)
                        .onAppear { if state.error != nil { repositoryIconFailed = true } }
                        .onChange(of: state.error != nil) { failed in
                            if failed { repositoryIconFailed = true }
                        }
                }
            }
        } else {
            Image("App_Unknown").appIconStyle(size: size)
                .task(id: app.id ?? app.currentName) {
                    catalogueIcon = await ZagGameArtworkClient.shared.iconURL(
                        bundleID: app.id, name: app.currentName
                    )
                }
        }
    }
}

/// The Featured card's geometry, shared by the card and its loading skeleton.
private enum ZagFeaturedCardMetrics {
    static let height: CGFloat = 250
    static let cornerRadius: CGFloat = 20
    static let padding: CGFloat = 14
    static let iconSize: CGFloat = 36
    static let iconSpacing: CGFloat = 9
    static let textSpacing: CGFloat = 4
    static let buttonHeight: CGFloat = 32
    static let cardSpacing: CGFloat = ZagGamesSectionTitle.columnGap
    static let maximumCards = 8
}

/// The two Featured carousels: Games and Emulators.
private enum ZagFeaturedShelf: Hashable {
    case games
    case emulators
}

/// A Featured card whose artwork is still loading: the finished card's
/// size and corners, with its bottom row (icon, title, subtitle, Get).
private struct ZagFeaturedCardSkeleton: View {
    let width: CGFloat

    private var iconRadius: CGFloat {
        // The app icon's own corner ratio (Image.appIconStyle).
        if #available(iOS 26.0, *) { return ZagFeaturedCardMetrics.iconSize * 0.2677 }
        return ZagFeaturedCardMetrics.iconSize * 0.2337
    }

    var body: some View {
        let metrics = ZagFeaturedCardMetrics.self
        ZStack(alignment: .bottomLeading) {
            ZagSkeletonFill.base
            HStack(alignment: .center, spacing: metrics.iconSpacing) {
                RoundedRectangle(cornerRadius: iconRadius, style: .continuous)
                    .fill(ZagSkeletonFill.element)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                // The title and subtitle lines' heights, with a bar in each.
                VStack(alignment: .leading, spacing: metrics.textSpacing) {
                    Capsule().fill(ZagSkeletonFill.element)
                        .frame(width: 132, height: 12)
                        .frame(height: 19)
                    Capsule().fill(ZagSkeletonFill.element)
                        .frame(width: 88, height: 9)
                        .frame(height: 16)
                }
                Spacer(minLength: 4)
                Capsule().fill(ZagSkeletonFill.element)
                    .frame(width: 64, height: metrics.buttonHeight)
            }
            .padding(metrics.padding)
        }
        .zagShimmer()
        .frame(width: width, height: metrics.height)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

private struct ZagGamesPage: View {
    // Body never reads repository state; indexing is driven by onReceive.
    private let sourcesModel = SourcesViewModel.shared
    @State private var selectedApp: SourceAppsView.SourceAppRoute?
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var dictationAvailable = false
    @State private var selectedCategory = "Games"
    @AppStorage("Feather.userTintColor") private var userTintColor = "#0090FF"
    @State private var categorySlide = ZagTabSlideState()
    @State private var showGameLibrary = false
    @State private var showCollections = false
    @State private var showGameFilters = false
    @State private var selectedGameRepository = "All"
    @State private var selectedGameGenre = "All"
    /// A genre or See All page opened from the pills or a shelf.
    @State private var gameList: ZagGameList?
    /// Genre names per game id, from the descriptions (built with the index).
    @State private var gameGenreTags: [String: [String]] = [:]
    @State private var searchScope = "All"
    @State private var indexedEmulators: [SourceAppsView.SourceAppRoute] = []
    @State private var indexedGames: [SourceAppsView.SourceAppRoute] = []
    @State private var indexedFeaturedGames: [SourceAppsView.SourceAppRoute] = []
    @State private var verifiedFeaturedGames: [SourceAppsView.SourceAppRoute] = []
    @State private var verifiedFeaturedEmulators: [SourceAppsView.SourceAppRoute] = []
    @State private var verifiedArtwork: [String: ZagFeaturedHero] = [:]
    /// The index revision each carousel last finished checking.
    @State private var featuredResolvedRevision: [ZagFeaturedShelf: Int] = [:]
    /// Carousels filling in card by card (their first check).
    @State private var featuredFillingIn: Set<ZagFeaturedShelf> = []
    /// Emulator artwork is checked only once Emulators is first opened.
    @State private var emulatorsFeaturedRequested = false
    /// Set when a repository refresh has finished (or after a time limit),
    /// so a catalogue that never indexes never shows skeletons forever.
    @State private var catalogueSettled = false
    @State private var sawRepositoryRefresh = false
    @State private var indexState = ZagRepositoryIndexState()
    @State private var indexWorker: Task<(ZagGamesIndexSnapshot, [String: [String]])?, Never>?
    @State private var indexedArtworkRevision = 0
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
        indexedGames.filter { entry in
            (searchText.isEmpty || matchesSearch(entry))
            && (selectedGameRepository == "All" || entry.source.name == selectedGameRepository)
            && (selectedGameGenre == "All" || gameGenre(entry.app.currentDescription ?? entry.app.localizedDescription ?? "") == selectedGameGenre)
        }
    }

    private var installedGames: [SourceAppsView.SourceAppRoute] {
        indexedGames.filter { entry in
            entry.app.id.map { UIApplication.isAppInstalled(with: $0) == true } ?? false
        }
    }

    private var gameRepositories: [String] {
        Array(Set(indexedGames.compactMap { $0.source.name })).sorted()
    }

    // MARK: Shelves

    /// Games per genre, for the pills.
    private var gameGenreCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for names in gameGenreTags.values {
            for name in names { counts[name, default: 0] += 1 }
        }
        return counts
    }

    /// Every loaded game in a genre, for its page.
    private func gamesTagged(_ genre: String) -> [SourceAppsView.SourceAppRoute] {
        indexedGames.filter { gameGenreTags[$0.id]?.contains(genre) == true }
    }

    /// Recently Updated, the biggest genres, then every game, each section
    /// short with a See All page.
    @ViewBuilder
    private var gameShelves: some View {
        let list = games
        if list.isEmpty {
            Text(catalogueLoading ? "Loading games from your sources…"
                 : selectedGameRepository != "All" || selectedGameGenre != "All" ? "No games match these filters."
                 : "No games identified in loaded repositories yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, Self.pageMargin)
        } else {
            let recent = list
                .filter { ZagGameRow.updatedDate($0) != nil }
                .sorted { (ZagGameRow.updatedDate($0) ?? .distantPast) > (ZagGameRow.updatedDate($1) ?? .distantPast) }
            VStack(alignment: .leading, spacing: 36) {
                if recent.count >= 3 {
                    shelf(ZagGameList(title: "Recently Updated", games: recent, subtitle: .updated))
                }
                ForEach(topGenres(in: list), id: \.genre.id) { item in
                    shelf(ZagGameList(title: item.genre.name, genre: item.genre, games: item.games))
                }
                allGamesSection(list)
            }
        }
    }

    private func shelf(_ list: ZagGameList) -> some View {
        ZagGameShelf(
            title: list.title,
            genre: list.genre,
            games: list.games,
            subtitle: list.subtitle,
            genreTags: gameGenreTags,
            margin: Self.pageMargin,
            open: { selectedApp = $0 },
            seeAll: { gameList = list }
        )
    }

    /// The three genres with the most games (at least three each).
    private func topGenres(in list: [SourceAppsView.SourceAppRoute]) -> [(genre: ZagGameGenre, games: [SourceAppsView.SourceAppRoute])] {
        ZagGameGenre.all
            .map { genre in (genre: genre, games: list.filter { gameGenreTags[$0.id]?.contains(genre.name) == true }) }
            .filter { $0.games.count >= 3 }
            .sorted { $0.games.count > $1.games.count }
            .prefix(3)
            .map { $0 }
    }

    private func allGamesSection(_ list: [SourceAppsView.SourceAppRoute]) -> some View {
        let shown = Array(list.prefix(8))
        return VStack(alignment: .leading, spacing: 2) {
            ZagGamesSectionTitle(title: "All Games", count: list.count) {
                gameList = ZagGameList(title: "All Games", games: list)
            }
            LazyVStack(spacing: 0) {
                ForEach(shown, id: \.id) { entry in
                    ZagGameRow(
                        entry: entry,
                        genres: gameGenreTags[entry.id] ?? [],
                        showsSeparator: entry.id != shown.last?.id
                    ) { selectedApp = entry }
                }
            }
        }
        .padding(.horizontal, Self.pageMargin)
    }

    /// The toggles button: a menu of the Game Filters.
    private var gameFiltersMenu: some View {
        Menu {
            Picker("Repository", selection: $selectedGameRepository) {
                Text("All Sources").tag("All")
                ForEach(gameRepositories, id: \.self) { name in Text(name).tag(name) }
            }
            .pickerStyle(.menu)
            Picker("Genre", selection: $selectedGameGenre) {
                Text("All Genres").tag("All")
                ForEach(gameGenres, id: \.self) { genre in Text(genre).tag(genre) }
            }
            .pickerStyle(.menu)
            if selectedGameRepository != "All" || selectedGameGenre != "All" {
                Divider()
                Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                    selectedGameRepository = "All"
                    selectedGameGenre = "All"
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Game Filters")
    }

    /// The Games page's side margin, as on the App Store.
    static let pageMargin: CGFloat = 20

    private let gameGenres = ["Puzzle", "Racing", "Strategy", "RPG", "Arcade", "Adventure", "Simulation", "Sports"]

    private func gameListRow(_ entry: SourceAppsView.SourceAppRoute) -> some View {
        Button {
            showGameLibrary = false
            showCollections = false
            selectedApp = entry
        } label: {
            HStack(spacing: 12) {
                ZagRepositoryAppIconView(app: entry.app, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.app.currentName).font(.headline).foregroundStyle(.primary)
                    Text(entry.source.name ?? "Repository")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // A card is eligible only after an actual screenshot passes download
    // and decoding checks. Never fill Featured with unverified placeholders.
    private func featured(_ shelf: ZagFeaturedShelf) -> [SourceAppsView.SourceAppRoute] {
        shelf == .games ? verifiedFeaturedGames : verifiedFeaturedEmulators
    }

    private func featuredCandidates(_ shelf: ZagFeaturedShelf) -> [SourceAppsView.SourceAppRoute] {
        shelf == .games ? indexedFeaturedGames : indexedEmulators
    }

    /// Repositories are still loading and nothing is indexed yet.
    private var catalogueLoading: Bool {
        indexedArtworkRevision == 0 && !sources.isEmpty && !catalogueSettled
    }

    /// The carousel's artwork is still being checked for this index.
    private func featuredLoading(_ shelf: ZagFeaturedShelf) -> Bool {
        if catalogueLoading { return true }
        guard !featuredCandidates(shelf).isEmpty else { return false }
        return featuredResolvedRevision[shelf] != indexedArtworkRevision
    }

    /// Placeholders after the finished cards: two (one full, one peeking)
    /// before any card is ready, then one while more cards fill in.
    private func featuredSkeletonCount(_ shelf: ZagFeaturedShelf) -> Int {
        let cards = featured(shelf).count
        guard cards < ZagFeaturedCardMetrics.maximumCards else { return 0 }
        if cards == 0 { return featuredLoading(shelf) ? 2 : 0 }
        return featuredFillingIn.contains(shelf) ? 1 : 0
    }

    // Match the App Store's landscape editorial format, with one compact app icon.
    private func featuredCard(
        for entry: SourceAppsView.SourceAppRoute,
        artwork: ZagFeaturedHero,
        width: CGFloat,
        shelf: ZagFeaturedShelf
    ) -> some View {
        let metrics = ZagFeaturedCardMetrics.self
        return Button { selectedApp = entry } label: {
            ZStack(alignment: .bottomLeading) {
                ZagFeaturedGameArtwork(hero: artwork, width: width)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.06), .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                HStack(alignment: .center, spacing: metrics.iconSpacing) {
                    ZagCatalogueBackedIcon(app: entry.app, size: metrics.iconSize)
                    VStack(alignment: .leading, spacing: metrics.textSpacing) {
                        Text(entry.app.currentName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        // Emulators name their platform, as in the list.
                        Text(shelf == .emulators
                             ? emulatorPlatform(entry.app.currentName)
                             : (entry.source.name ?? "Repository"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("Get")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 19)
                        .frame(height: metrics.buttonHeight)
                        .background(.white.opacity(0.36), in: Capsule())
                        .environment(\.colorScheme, .dark)
                }
                .padding(metrics.padding)
            }
            .frame(width: width, height: metrics.height)
            // Flatten first, so the corners clip every layer of the card.
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(shelf == .emulators
            ? "Opens emulator details and installation options"
            : "Opens game details and installation options")
    }

    // Process only a few candidates concurrently so giant repositories never
    // trigger an unbounded burst of App Store and screenshot requests.
    //
    // A carousel's first check reveals each card as soon as its artwork is
    // verified. Later checks (a refresh) keep the current cards until the
    // new set is complete, then swap it in at once, so nothing flickers.
    @MainActor
    private func refreshVerifiedFeatured(_ shelf: ZagFeaturedShelf) async {
        let revision = indexedArtworkRevision
        let candidates = featuredCandidates(shelf)
        let fillingIn = featured(shelf).isEmpty
        let startedAt = Date()
        var cards: [SourceAppsView.SourceAppRoute] = []
        var artwork: [String: ZagFeaturedHero] = [:]

        if fillingIn { featuredFillingIn.insert(shelf) }
        defer { featuredFillingIn.remove(shelf) }

        for start in stride(from: 0, to: candidates.count, by: 4) {
            guard !Task.isCancelled else { return }
            let end = min(start + 4, candidates.count)
            var successes: [(Int, ZagVerifiedFeaturedArtwork)] = []

            await withTaskGroup(of: (Int, ZagVerifiedFeaturedArtwork?).self) { group in
                for index in start..<end {
                    let entry = candidates[index]
                    let candidate = ZagFeaturedArtworkCandidate(
                        index: index,
                        bundleID: entry.app.id,
                        name: entry.app.currentName,
                        screenshots: entry.app.currentScreenshotURLs
                    )
                    group.addTask {
                        let artwork = await ZagFeaturedArtworkResolver.shared.resolve(
                            bundleID: candidate.bundleID,
                            name: candidate.name,
                            repositoryScreenshots: candidate.screenshots
                        )
                        return (candidate.index, artwork)
                    }
                }
                for await (index, artwork) in group {
                    if let artwork { successes.append((index, artwork)) }
                }
            }

            guard !Task.isCancelled else { return }
            var added = false
            for (index, payload) in successes.sorted(by: { $0.0 < $1.0 }) {
                guard cards.count < ZagFeaturedCardMetrics.maximumCards,
                      let hero = ZagFeaturedHero.make(from: payload) else { continue }
                let entry = candidates[index]
                let nameKey = normalizedName(entry.app.currentName)
                guard !cards.contains(where: {
                    normalizedName($0.app.currentName) == nameKey
                }) else { continue }
                artwork[entry.id] = hero
                cards.append(entry)
                added = true
            }
            if fillingIn && added {
                // Cached artwork resolves at once: show it without a fade.
                publishFeatured(shelf, cards: cards, artwork: artwork,
                                animated: Date().timeIntervalSince(startedAt) > 0.15)
            }
            if cards.count >= ZagFeaturedCardMetrics.maximumCards { break }
        }

        guard !Task.isCancelled else { return }
        if !fillingIn || cards.isEmpty {
            publishFeatured(shelf, cards: cards, artwork: artwork, animated: false)
        }
        featuredResolvedRevision[shelf] = revision
    }

    /// Shows a carousel's cards, keeping artwork the other carousel uses.
    @MainActor
    private func publishFeatured(
        _ shelf: ZagFeaturedShelf,
        cards: [SourceAppsView.SourceAppRoute],
        artwork: [String: ZagFeaturedHero],
        animated: Bool
    ) {
        let other = Set(featured(shelf == .games ? .emulators : .games).map(\.id))
        var nextArtwork = verifiedArtwork.filter { other.contains($0.key) }
        nextArtwork.merge(artwork) { _, new in new }
        let apply = {
            verifiedArtwork = nextArtwork
            if shelf == .games { verifiedFeaturedGames = cards } else { verifiedFeaturedEmulators = cards }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25), apply)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, apply)
        }
    }

    /// The Featured carousel for Games or Emulators. Each position shows a
    /// skeleton until its card's artwork is verified, then the card fades
    /// in over it, so the carousel never changes size or jumps.
    @ViewBuilder
    private func featuredSection(_ shelf: ZagFeaturedShelf) -> some View {
        let cards = featured(shelf)
        let skeletons = featuredSkeletonCount(shelf)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                ZagGamesSectionTitle(title: "Featured")
                Spacer()
                Text("From your sources")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if cards.isEmpty && skeletons == 0 {
                Text(shelf == .games
                     ? "No verified game screenshots are available from the current repositories or Apple catalogue."
                     : "No verified emulator screenshots are available from the current repositories or Apple catalogue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
            GeometryReader { geometry in
                let width = geometry.size.width
                ScrollView(.horizontal, showsIndicators: false) {
                    // Eight featured entries at most: eager layout
                    // avoids late-appearing cards while scrolling.
                    HStack(spacing: ZagFeaturedCardMetrics.cardSpacing) {
                        ForEach(0..<(cards.count + skeletons), id: \.self) { slot in
                            ZStack {
                                if slot >= cards.count {
                                    ZagFeaturedCardSkeleton(width: width)
                                        // Leaves only once the card has faded in.
                                        .transition(.asymmetric(
                                            insertion: .opacity,
                                            removal: .opacity.animation(.easeOut(duration: 0.12).delay(0.25))
                                        ))
                                }
                                if slot < cards.count, let artwork = verifiedArtwork[cards[slot].id] {
                                    featuredCard(for: cards[slot], artwork: artwork, width: width, shelf: shelf)
                                        .transition(.opacity)
                                }
                            }
                            .frame(width: width, height: ZagFeaturedCardMetrics.height)
                        }
                    }
                    .padding(.trailing, ZagGamesPage.pageMargin)
                    .padding(.vertical, 2)
                }
                // Out to the screen edge, so 10 points of the next card show.
                .frame(width: width + ZagGamesPage.pageMargin, alignment: .leading)
                .modifier(ZagGamesScrollClipModifier())
            }
            .frame(height: ZagFeaturedCardMetrics.height + 4)
            }
        }
    }

    // Starting the scan must not block the Games tab transition.
    // Keep current results visible until the new version is ready.
    private func indexSignature(for loaded: [AltSource: ASRepository]) -> String {
        sources.map { source in
            let key = source.identifier ?? source.sourceURL?.absoluteString ?? source.objectID.uriRepresentation().absoluteString
            return key + ":" + String(loaded[source]?.apps.count ?? -1)
        }.joined(separator: "|")
    }

    private func loadedCount(in loaded: [AltSource: ASRepository]) -> Int {
        sources.reduce(0) { $0 + (loaded[$1] == nil ? 0 : 1) }
    }

    /// Starts the build that `indexState` asked for, from the repository
    /// snapshot that triggered it (never from a later read of the model).
    private func buildIndex(generation: Int?, from loaded: [AltSource: ASRepository]) {
        guard let generation else { return }

        // Copy repository *values* on the main actor, without copying Core Data
        // source objects to a background executor.
        let repositories = sources.compactMap { loaded[$0] }
        let indexStartedAt = ZagPerformanceMonitor.now()
        indexWorker?.cancel()
        let worker = Task.detached(priority: .userInitiated) { () -> (ZagGamesIndexSnapshot, [String: [String]])? in
            let catalogue = await ZagAppleGameCatalogue.shared.knownGames()
            guard let snapshot = ZagGamesIndexBuilder.build(repositories, catalogue: catalogue) else { return nil }
            return (snapshot, catalogue)
        }
        indexWorker = worker

        Task { @MainActor in
            guard let (snapshot, catalogue) = await worker.value,
                  !worker.isCancelled,
                  indexState.accepts(generation: generation) else { return }

            indexedFeaturedGames = snapshot.featuredCandidates
            indexedEmulators = snapshot.emulators
            indexedGames = snapshot.games
            let games = snapshot.games
            let tags = await Task.detached(priority: .userInitiated) {
                ZagGameGenrePills.tags(for: games, appleGenres: catalogue)
            }.value
            // A newer index may have started meanwhile; it brings its own.
            if indexState.accepts(generation: generation) { gameGenreTags = tags }
            indexedEmulatorCount = snapshot.emulators.count
            indexedGameCount = snapshot.games.count
            indexedArtworkRevision += 1
            ZagPerformanceMonitor.shared.record(
                .gamesCatalogueIndex,
                since: indexStartedAt,
                result: "repositories=\(repositories.count), games=\(snapshot.games.count), emulators=\(snapshot.emulators.count)"
            )
            classifyWithAppleCatalogue(snapshot.bundleIDs)
        }
    }

    /// Asks Apple's catalogue about apps not checked yet (in the background,
    /// saved on the device) and rebuilds the index when it finds games.
    private func classifyWithAppleCatalogue(_ bundleIDs: [String]) {
        Task.detached(priority: .utility) {
            await ZagAppleGameCatalogue.shared.classify(bundleIDs) { _ in
                await MainActor.run {
                    let loaded = sourcesModel.sources
                    buildIndex(
                        generation: indexState.catalogueClassified(
                            signature: indexSignature(for: loaded),
                            loadedRepositoryCount: loadedCount(in: loaded)
                        ),
                        from: loaded
                    )
                }
            }
        }
    }

    // Settings → App Icon's native scope bar (a hidden search bar's scope,
    // which never brings up the keyboard). Pinned to its row, so it stays
    // centred and can never draw over the genre links.
    private var gamesCategorySwitcher: some View {
        ZagScopeBar(
            selection: $selectedCategory.zagTabSlide($categorySlide, order: ["Games", "Emulators"]),
            titles: ["Games", "Emulators"],
            pinnedToRow: true
        )
        .frame(maxWidth: .infinity)
        // A little taller than the control, so clipping never trims it.
        .frame(height: ZagScopeBar.controlHeight + 4)
        .accessibilityLabel("Gaming Category")
    }

    var body: some View {
        NBNavigationView("Games") {
            ScrollView {
                // Genre links in place of a search bar, edge to edge.
                ZagGameGenrePills(margin: Self.pageMargin, counts: gameGenreCounts, loading: catalogueLoading) { genre in
                    gameList = ZagGameList(title: genre.name, genre: genre, games: gamesTagged(genre.name))
                }
                .padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) {
                // Outside the lazy stack below, so scrolling never discards
                // and rebuilds the switcher.
                if !searchFieldFocused {
                    // A caps line over the switcher, like the App Store's
                    // PRE-ORDER label over a featured title.
                    VStack(alignment: .leading, spacing: 6) {
                        // Fixed at 13-point semibold like PRE-ORDER, which
                        // does not grow with the reader's text size.
                        Text("PLAY NATIVE OR EMULATE")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ZagWideGamutTint.color(hex: userTintColor))
                        gamesCategorySwitcher
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.pageMargin)
                    .padding(.top, 18)
                }
                LazyVStack(alignment: .leading, spacing: 22) {

                    if !searchFieldFocused && selectedCategory == "Games" &&
                        (!indexedGames.isEmpty || featuredLoading(.games)) {
                        featuredSection(.games)
                            .zagTabSlideIn(categorySlide)
                    }

                    if !searchFieldFocused && selectedCategory == "Emulators" &&
                        (!indexedEmulators.isEmpty || featuredLoading(.emulators)) {
                        featuredSection(.emulators)
                            .zagTabSlideIn(categorySlide)
                    }

                    if searchFieldFocused ? (searchScope == "All" || searchScope == "Emulators") : selectedCategory == "Emulators" {
                    VStack(alignment: .leading, spacing: 10) {
                        ZagGamesSectionTitle(title: "Emulators", count: emulators.count)
                        Text("Explore platforms from your sources")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if emulators.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "gamecontroller")
                                    .font(.system(size: 35, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text(!searchText.isEmpty ? "No matching emulators"
                                     : catalogueLoading ? "Loading your repositories…" : "No emulators indexed yet")
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
                                    ZagGameRow(
                                        entry: entry,
                                        subtitle: .text(emulatorPlatform(entry.app.currentName)),
                                        showsSeparator: entry.id != emulators.last?.id
                                    ) { selectedApp = entry }
                                }
                            }
                        }
                    }
                    .zagTabSlideIn(categorySlide)

                    }
                }
                .padding(.horizontal, Self.pageMargin)
                // 22 points below the switcher (its row has 2 points of
                // slack), or 18 below the genre links without it.
                .padding(.top, searchFieldFocused ? 18 : 20)
                .padding(.bottom, selectedCategory == "Games" ? 40 : 90)
                }

                if selectedCategory == "Games" {
                    gameShelves
                        .padding(.bottom, 90)
                        .zagTabSlideIn(categorySlide)
                }
            }
            .modifier(ZagSoftTopEdge())
            .zagWallpaperSurface()
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear {
                let loaded = sourcesModel.sources
                buildIndex(
                    generation: indexState.appeared(
                        signature: indexSignature(for: loaded),
                        loadedRepositoryCount: loadedCount(in: loaded)
                    ),
                    from: loaded
                )
            }
            // Resolve artwork only once the background index has been published.
            .task(id: indexedArtworkRevision) {
                await refreshVerifiedFeatured(.games)
            }
            // Emulator artwork is requested the first time Emulators opens,
            // then kept (switching tabs never restarts it).
            .task(id: emulatorsFeaturedRequested ? indexedArtworkRevision : -1) {
                guard emulatorsFeaturedRequested else { return }
                await refreshVerifiedFeatured(.emulators)
            }
            .onChange(of: selectedCategory) { category in
                if category == "Emulators" { emulatorsFeaturedRequested = true }
            }
            .onReceive(sourcesModel.$isRefreshing) { refreshing in
                if refreshing {
                    sawRepositoryRefresh = true
                } else if sawRepositoryRefresh {
                    catalogueSettled = true
                }
            }
            .task {
                // Never show loading cards indefinitely if repositories
                // never finish loading.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                catalogueSettled = true
            }
            // Index from the values Combine publishes, not from the model read
            // later: @Published emits before it stores the new value.
            .onReceive(sourcesModel.$sources) { loaded in
                buildIndex(
                    generation: indexState.repositoriesPublished(
                        signature: indexSignature(for: loaded),
                        loadedRepositoryCount: loadedCount(in: loaded),
                        isRefreshing: sourcesModel.isRefreshing
                    ),
                    from: loaded
                )
            }
            // A refresh ends (finished, failed or cancelled) by clearing
            // isRefreshing, after its final repository snapshot is stored.
            .onReceive(sourcesModel.$isRefreshing.dropFirst()) { refreshing in
                guard !refreshing else { return }
                let loaded = sourcesModel.sources
                buildIndex(
                    generation: indexState.refreshEnded(
                        signature: indexSignature(for: loaded),
                        loadedRepositoryCount: loadedCount(in: loaded)
                    ),
                    from: loaded
                )
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { selectedApp != nil },
                    set: { if !$0 { selectedApp = nil } }
                )
            ) {
                if let selectedApp {
                    SourceAppsDetailView(
                        source: selectedApp.source,
                        app: selectedApp.app,
                        prefetchedFeaturedHero: verifiedArtwork[selectedApp.id]?.detailHero
                    )
                }
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { gameList != nil },
                    set: { if !$0 { gameList = nil } }
                )
            ) {
                if let gameList {
                    ZagGameListPage(list: gameList, genreTags: gameGenreTags)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    gameFiltersMenu
                    Button { showGameLibrary = true } label: {
                        ZagPrimaryTabIcons.label(for: .games)
                            .frame(width: 30, height: 30)
                    }
                        .accessibilityLabel("Game Library")
                }
                ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showCollections = true } label: {
                        ZagPrimaryTabIcons.label(for: .collections)
                            .frame(width: 30, height: 30)
                    }
                        .accessibilityLabel("Game Collections")
                    ZagProfileToolbarButton()
                        .tint(.primary)
                        .padding(.trailing, -2)
                }
            }
            .sheet(isPresented: $showGameLibrary) {
                NavigationStack {
                    List {
                        ForEach(installedGames, id: \.id) { entry in gameListRow(entry) }
                    }
                    .overlay {
                        if installedGames.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "gamecontroller")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text("No Installed Games").font(.headline)
                                Text("Installed games from your loaded repositories will appear here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(24)
                        }
                    }
                    .navigationTitle("Game Library")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showGameLibrary = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showCollections) {
                NavigationStack {
                    List {
                        ForEach(gameGenres, id: \.self) { genre in
                            let entries = indexedGames.filter {
                                gameGenre($0.app.currentDescription ?? $0.app.localizedDescription ?? "") == genre
                            }
                            if !entries.isEmpty {
                                Section(genre) {
                                    ForEach(entries.prefix(12), id: \.id) { entry in gameListRow(entry) }
                                }
                            }
                        }
                    }
                    .overlay {
                        if indexedGames.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "trophy")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text("No Collections Yet").font(.headline)
                                Text("Collections are assembled from games in your repositories.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(24)
                        }
                    }
                    .navigationTitle("Collections")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showCollections = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showGameFilters) {
                NavigationStack {
                    Form {
                        Picker("Repository", selection: $selectedGameRepository) {
                            Text("All Repositories").tag("All")
                            ForEach(gameRepositories, id: \.self) { name in Text(name).tag(name) }
                        }
                        Picker("Genre", selection: $selectedGameGenre) {
                            Text("All Genres").tag("All")
                            ForEach(gameGenres, id: \.self) { genre in Text(genre).tag(genre) }
                        }
                        Button("Reset Filters") {
                            selectedGameRepository = "All"
                            selectedGameGenre = "All"
                        }
                    }
                    .navigationTitle("Game Filters")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showGameFilters = false }
                        }
                    }
                }
            }
        }
    }
}

/// The Featured collection receives only artwork downloaded and validated by
/// ZagFeaturedArtworkResolver. It never draws empty geometric hero cards.
private enum ZagFeaturedHero {
    case landscape(UIImage)
    case portraits([UIImage])
    case landscapeStrips([UIImage])

    @MainActor
    static func make(from payload: ZagVerifiedFeaturedArtwork) -> ZagFeaturedHero? {
        let images = payload.images.compactMap { UIImage(data: $0.data) }
        guard !images.isEmpty else { return nil }
        switch payload.layout {
        case .landscape: return .landscape(images[0])
        case .portraits: return .portraits(images)
        case .landscapeStrips: return .landscapeStrips(images)
        }
    }
}

// The Featured Games card already holds image bytes verified by the same
// resolver. Reuse those exact images when opening detail, with no second
// download or placeholder transition.
private extension ZagFeaturedHero {
    var detailHero: ZagAppDetailHeaderHero {
        switch self {
        case .landscape(let image): return .landscape(image)
        case .portraits(let images): return .portraits(images)
        case .landscapeStrips(let images): return .landscapeStrips(images)
        }
    }
}

private struct ZagFeaturedGameArtwork: View {
    let hero: ZagFeaturedHero
    let width: CGFloat

    var body: some View {
        ZStack {
            Color.black
            switch hero {
            case .landscape(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: 250)
                    .clipped()

            case .portraits(let images):
                // Do not inflate a single small portrait to the entire card
                // or copy it repeatedly to pretend other screenshots exist.
                HStack(spacing: 2) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(uiImage: images[index])
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: images.count == 1 ? width * 0.48 :
                                    (width - CGFloat(images.count - 1) * 2) / CGFloat(images.count),
                                height: 250
                            )
                            .clipped()
                    }
                }
                .frame(width: width, height: 250,
                       alignment: images.count == 1 ? .trailing : .center)
                .clipped()

            case .landscapeStrips(let images):
                VStack(spacing: 2) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(uiImage: images[index])
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: images.count == 1 ? width * 0.70 : width,
                                height: images.count == 1 ? 165 :
                                    (250 - CGFloat(images.count - 1) * 2) / CGFloat(images.count)
                            )
                            .clipped()
                    }
                }
                .frame(width: width, height: 250)
                .clipped()
            }
        }
        .frame(width: width, height: 250)
        .clipped()
    }
}

private struct ZagActivityPage: View {
    @StateObject private var sourcesModel = SourcesViewModel.shared
    @StateObject private var updateTransactions = ZagUpdateTransactionManager.shared
    @State private var historyFilter = "All"
    @State private var historySlide = ZagTabSlideState()
    @AppStorage("ZagStore.activity.sortOrder") private var sortOrder = "Newest First"
    @State private var showStatistics = false
    @State private var selectedHistoryRecord: ZagUpdateTransactionManager.ActivityRecord?
    @State private var showRepositoryDetails = false
    @State private var historySearchText = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var dictationAvailable = false
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

    private var filteredHistory: [ZagUpdateTransactionManager.ActivityRecord] {
        let statusFiltered = consolidatedHistory.filter { historyFilter == "All" || $0.status == historyFilter }
        let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = query.isEmpty ? statusFiltered : statusFiltered.filter { record in
            (record.appName?.localizedCaseInsensitiveContains(query) ?? false)
            || record.updateID.localizedCaseInsensitiveContains(query)
            || (record.detail?.localizedCaseInsensitiveContains(query) ?? false)
            || record.status.localizedCaseInsensitiveContains(query)
        }
        switch sortOrder {
        case "Oldest First": return searched.sorted { $0.timestamp < $1.timestamp }
        case "App Name": return searched.sorted { ($0.appName ?? $0.updateID).localizedStandardCompare($1.appName ?? $1.updateID) == .orderedAscending }
        default: return searched.sorted { $0.timestamp > $1.timestamp }
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
                        // Same 12-point section rhythm as Games > Featured.
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("History").font(.title2.bold())
                                Spacer()
                                Text("\(consolidatedHistory.count) operations")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            ZagScopeBar(
                                selection: $historyFilter.zagTabSlide(
                                    $historySlide,
                                    order: ["All", "Installed", "Signed", "Ready to Install", "Failed"]
                                ),
                                titles: ["All", "Installed", "Signed", "Prepared", "Failed"],
                                values: ["All", "Installed", "Signed", "Ready to Install", "Failed"]
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: ZagScopeBar.controlHeight)
                            .accessibilityLabel("History Filter")
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
                            .zagTabSlideIn(historySlide)
                            .id(historyFilter)
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
            .searchable(text: $historySearchText, placement: .platform(), prompt: Text("Search Activity"))
            .modifier(ZagRepositorySearchFocusModifier(isFocused: $searchFieldFocused))
            .background {
                ZagNativeSearchMicInstaller(
                    isAvailable: dictationAvailable,
                    action: startDictationFromSearchMic,
                    prompt: "Search Activity",
                    activePrompt: "Search Activity"
                )
                .frame(width: 0, height: 0)
            }
            .onAppear(perform: probeSystemDictation)
            .sheet(isPresented: $showStatistics) {
                NavigationStack {
                    List {
                        Section("Operations") {
                            LabeledContent("Total", value: consolidatedHistory.count.formatted())
                            LabeledContent("Installed", value: consolidatedHistory.filter { $0.status == "Installed" }.count.formatted())
                            LabeledContent("Signed", value: consolidatedHistory.filter { $0.status == "Signed" }.count.formatted())
                            LabeledContent("Failed", value: consolidatedHistory.filter { $0.status == "Failed" }.count.formatted())
                        }
                        Section("Repositories") {
                            LabeledContent("Loaded", value: loadedRepositories.formatted())
                            LabeledContent("Indexed Apps", value: loadedApps.formatted())
                        }
                    }
                    .navigationTitle("Activity Statistics")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showStatistics = false }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Menu {
                        Picker("Filter Activity", selection: $historyFilter) {
                            Text("All").tag("All")
                            Text("Installed").tag("Installed")
                            Text("Signed").tag("Signed")
                            Text("Prepared").tag("Ready to Install")
                            Text("Failed").tag("Failed")
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Filter Activity")
                    Button { showStatistics = true } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel("Activity Statistics")
                }
                ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort Activity", selection: $sortOrder) {
                            Text("Newest First").tag("Newest First")
                            Text("Oldest First").tag("Oldest First")
                            Text("App Name").tag("App Name")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort Activity")
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


/// The frosted fade under the header that Apps and Sources show while
/// scrolling, rather than a solid band with a hard lower edge.
private struct ZagSoftTopEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct ZagGamesScrollClipModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

 
// Native dock editor; its persisted order is shared by both tab-bar implementations.
struct ZagDockCustomizationView: View {
    @AppStorage(ZagDockConfiguration.storageKey) private var storedTabs = ""
    @AppStorage(ZagDockConfiguration.shrinkOnScrollKey) private var shrinkOnScroll = false
    @State private var showLimitAlert = false
    @State private var showLastTabAlert = false
    @AppStorage("Feather.userTintColor") private var themeTintHex = "#0090FF"
    private var themeTint: Color { ZagWideGamutTint.color(hex: themeTintHex) }
    // Reuse the exact artwork shown in the live dock, rather than TabEnum's
    // legacy SF Symbol fallbacks. This also keeps the reorder list in sync.
    @ViewBuilder
    private func dockIcon(for tab: TabEnum) -> some View {
        switch tab {
        case .discover:
            ZagPrimaryTabIcons.label(for: .discover)
        case .sources:
            ZagSourcesTabIcon.label
        case .games:
            ZagPrimaryTabIcons.label(for: .games)
        case .activity:
            ZagPrimaryTabIcons.label(for: .activity)
        case .settings:
            ZagPrimaryTabIcons.label(for: .settings)
        default:
            Image(systemName: tab.icon)
        }
    }

    private func tintedLabel(_ tab: TabEnum) -> some View {
        Label { Text(tab.title) } icon: {
            dockIcon(for: tab)
                .foregroundStyle(themeTint)
        }
    }

    private var active: [TabEnum] { ZagDockConfiguration.tabs }

    private var shrinkSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                Toggle("Shrink on Scroll", isOn: $shrinkOnScroll)
                    .disabled(!shrinkSupported)
            } header: {
                Text("Behaviour")
            } footer: {
                Text(shrinkSupported
                    ? "The dock shrinks to the current page's icon as you scroll down. Tap it to expand the dock again."
                    : "Shrink on Scroll requires iOS 26.")
            }
            Section {
                ForEach(ZagDockConfiguration.choices, id: \.rawValue) { tab in
                    Toggle(isOn: Binding(
                        get: { active.contains(tab) },
                        set: { enabled in
                            var tabs = active
                            if enabled {
                                guard tabs.count < 5 else { showLimitAlert = true; return }
                                tabs.append(tab)
                            } else {
                                guard tabs.count > 1 else { showLastTabAlert = true; return }
                                tabs.removeAll { $0 == tab }
                            }
                            ZagDockConfiguration.save(tabs)
                            storedTabs = tabs.map(\.rawValue).joined(separator: ",")
                        }
                    )) {
                        tintedLabel(tab)
                    }
                }
            } header: {
                HStack {
                    Text("Visible Tabs")
                    Spacer()
                    Text("\(active.count) / 5")
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(themeTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(themeTint.opacity(0.14), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(themeTint.opacity(0.5), lineWidth: 1)
                        }
                }
            } footer: {
                Text("Choose up to five destinations. Hidden pages remain accessible through the account menu.")
            }
            Section {
                ForEach(active, id: \.rawValue) { tab in
                    tintedLabel(tab)
                }
                .onMove { indices, destination in
                    var tabs = active
                    tabs.move(fromOffsets: indices, toOffset: destination)
                    ZagDockConfiguration.save(tabs)
                    storedTabs = tabs.map(\.rawValue).joined(separator: ",")
                }
            } header: {
                Text("Dock Order")
            } footer: {
                Text("Drag the handles to rearrange the dock.")
            }
            Section {
                Button {
                    ZagDockConfiguration.reset()
                    storedTabs = ZagDockConfiguration.defaults.map(\.rawValue).joined(separator: ",")
                } label: {
                    Label { Text("Reset to Default") } icon: { Image(systemName: "arrow.counterclockwise").foregroundStyle(themeTint) }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Bottom Dock")
        .alert("Dock Limit Reached", isPresented: $showLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can display up to five tabs. Disable another tab before enabling this one.")
        }
        .alert("Keep One Tab", isPresented: $showLastTabAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("At least one destination must remain in the dock.")
        }
    }
}

//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import NimbleViews

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
        case "devices": return .devices
        default: return nil
        }
    }

	var title: String {
		switch self {
		case .discover:		return "Discover"
		case .activity:		return "Activity"
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
		case .devices: ZagDevicesPage()
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
			.activity,
			.devices
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
        let name = entry.app.currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? saveKey(entry) : name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 18, weight: .medium))
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
private struct ZagActivityPage: View {
    var body: some View {
        NBNavigationView("Activity") {
            ZagEmptyDestination(title: "No Recent Activity", symbol: "clock.arrow.circlepath",
                message: "App installation, signing and refresh activity will appear here.")
                .toolbar {
                    ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                    ToolbarItem(placement: .topBarTrailing) { ZagProfileToolbarButton() }
                }
        }
    }
}

private struct ZagDevicesPage: View {
    @State private var batteryLevel: Float = -1
    @State private var batteryState: UIDevice.BatteryState = .unknown
    @State private var storageAvailable: Int64?
    @State private var storageTotal: Int64?

    private var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafeBytes(of: machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
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
        NBNavigationView("Devices") {
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
            .toolbar {
                ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                ToolbarItem(placement: .topBarTrailing) { ZagProfileToolbarButton() }
            }
        }
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

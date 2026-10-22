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
    @State private var selectedInterest: String?
    @State private var selectedApp: Entry?
    @State private var indexedEntries: [Entry] = []
    @FetchRequest(
        entity: AltSource.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
    ) private var sources: FetchedResults<AltSource>

    private typealias Entry = SourceAppsView.SourceAppRoute

    private var entries: [Entry] { indexedEntries }

    private func rebuildIndex() {
        indexedEntries = sources.flatMap { source in
            guard let repository = viewModel.sources[source] else { return [Entry]() }
            return repository.apps.map { Entry(source: repository, app: $0) }
        }
    }

    private var matching: [Entry] {
        guard !searchText.isEmpty || selectedInterest != nil else { return entries }
        let terms = interests.first { $0.name == selectedInterest }?.terms ?? []
        return entries.filter { entry in
            let name = entry.app.currentName.lowercased()
            let description = (entry.app.currentDescription ?? entry.app.localizedDescription ?? "").lowercased()
            let interestMatch = terms.isEmpty || terms.contains { name.contains($0) || description.contains($0) }
            return interestMatch && (searchText.isEmpty || (
            entry.app.currentName.localizedCaseInsensitiveContains(searchText)
            || (entry.app.id?.localizedCaseInsensitiveContains(searchText) ?? false)
            || (entry.app.currentDescription?.localizedCaseInsensitiveContains(searchText) ?? false)))
        }
    }

    private var recent: [Entry] {
        Array(matching.filter { $0.app.currentDate?.date != nil }
            .sorted { ($0.app.currentDate?.date ?? .distantPast) > ($1.app.currentDate?.date ?? .distantPast) }
            .prefix(15))
    }

    private var acrossSources: [Entry] {
        let grouped = Dictionary(grouping: matching.compactMap { entry -> (String, Entry)? in
            guard let id = entry.app.id, !id.isEmpty else { return nil }
            return (id.lowercased(), entry)
        }, by: { $0.0 })
        return Array(grouped.values.filter {
            Set($0.map { $0.1.source.id ?? $0.1.source.name ?? "" }).count > 1
        }.compactMap { group in
            group.map(\.1).max { ($0.app.currentDate?.date ?? .distantPast) < ($1.app.currentDate?.date ?? .distantPast) }
        }.sorted { $0.app.currentName.localizedStandardCompare($1.app.currentName) == .orderedAscending }.prefix(12))
    }

    private var spotlight: [Entry] {
        var seen = Set<String>()
        return Array(recent.filter { entry in
            guard let id = entry.app.id, !id.isEmpty else { return false }
            guard let description = entry.app.currentDescription ?? entry.app.localizedDescription,
                  description.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 else { return false }
            return seen.insert(id.lowercased()).inserted
        }.prefix(5))
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

    private func interestMatches(_ interest: Interest) -> [Entry] {
        var seen = Set<String>()
        return Array(matching.filter { entry in
            let name = entry.app.currentName.lowercased()
            let description = (entry.app.currentDescription ?? entry.app.localizedDescription ?? "").lowercased()
            let matched = interest.terms.contains { name.contains($0) || description.contains($0) }
            let key = (entry.app.id ?? entry.id).lowercased()
            return matched && seen.insert(key).inserted
        }.prefix(12))
    }

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
                                        let matches = interestMatches(interest)
                                        if !matches.isEmpty {
                                            Button {
                                                selectedInterest = selectedInterest == interest.name ? nil : interest.name
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Image(systemName: interest.symbol)
                                                        .foregroundStyle(.tint)
                                                    Text(interest.name).font(.subheadline.weight(.semibold))
                                                }
                                                .padding(.horizontal, 15)
                                                .padding(.vertical, 13)
                                                .background(.quaternary.opacity(0.4), in: Capsule())
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
                                                    Image(systemName: "square.stack.3d.up.fill")
                                                        .font(.title2)
                                                        .foregroundStyle(.tint)
                                                    Spacer(minLength: 0)
                                                    Text(repository.name ?? source.name ?? "Repository")
                                                        .font(.headline).lineLimit(2)
                                                    Text("\(repository.apps.count.formatted()) apps")
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                                .frame(width: 155, height: 125, alignment: .leading)
                                                .padding(16)
                                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
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
            .onAppear(perform: rebuildIndex)
            .onChange(of: viewModel.isFinished) { _ in rebuildIndex() }
            .onChange(of: viewModel.sources.count) { _ in rebuildIndex() }
            .onChange(of: sources.count) { _ in rebuildIndex() }
            .searchable(text: $searchText, placement: .platform(), prompt: "Search Discover")
            .zagWallpaperSurface()
            .toolbar {
                ToolbarItem(placement: .principal) { ZagLocalVPNToolbarStatus() }
                ToolbarItem(placement: .topBarTrailing) { ZagProfileToolbarButton() }
            }
        }
    }

    private func spotlightCard(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZagRepositoryAppIconView(app: entry.app, size: 74)
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(entry.app.currentName)
                .font(.title2.bold()).lineLimit(1)
            Text(entry.app.currentDescription ?? entry.app.localizedDescription ?? "")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Text(entry.source.name ?? "Repository")
                .font(.caption.weight(.semibold)).foregroundStyle(.tint).lineLimit(1)
        }
        .padding(20)
        .frame(width: 285, height: 245, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.045)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.accentColor.opacity(0.16)))
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
                                VStack(alignment: .leading, spacing: 10) {
                                    ZagRepositoryAppIconView(app: entry.app, size: 72)
                                    Text(entry.app.currentName)
                                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(entry.source.name ?? "Repository")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 112, alignment: .leading)
                            }
                            .buttonStyle(.plain)
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

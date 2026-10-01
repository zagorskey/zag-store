//
//  SourceAppsTableView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit

private struct ZagGitHubHistoricalIPA: Hashable {
	let version: String
	let release: String
	let downloadURL: URL
}

private struct ZagGitHubHistoryDiagnostic {
	let repository: String
	let status: Int
	let releases: Int
	let ipaAssets: Int
	let matchedAssets: Int
	let error: String?
}

private final class ZagGitHubHistoryResolver {
	static let shared = ZagGitHubHistoryResolver()
	private var cache: [String: [ZagGitHubHistoricalIPA]] = [:]
	private var loading = Set<String>()
	private var waiters: [String: [([ZagGitHubHistoricalIPA], ZagGitHubHistoryDiagnostic) -> Void]] = [:]
	private let lock = NSLock()

	func cached(for app: ASRepository.App) -> [ZagGitHubHistoricalIPA] {
		let key = cacheKey(for: app)
		lock.lock(); defer { lock.unlock() }
		return cache[key] ?? []
	}

	func resolve(_ app: ASRepository.App, completion: @escaping ([ZagGitHubHistoricalIPA], ZagGitHubHistoryDiagnostic) -> Void) {
		guard let repository = repositoryForHistory(of: app) else {
			let diagnostic = ZagGitHubHistoryDiagnostic(repository: "not resolved", status: -1, releases: 0, ipaAssets: 0, matchedAssets: 0, error: "No GitHub repository found")
			DispatchQueue.main.async { completion([], diagnostic) }
			return
		}

		let key = cacheKey(for: app)
		lock.lock()
		waiters[key, default: []].append(completion)
		if loading.contains(key) { lock.unlock(); return }
		loading.insert(key)
		lock.unlock()

		guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100") else {
			finish(key: key, items: [], diagnostic: .init(repository: repository, status: -1, releases: 0, ipaAssets: 0, matchedAssets: 0, error: "Invalid API URL"))
			return
		}
		var request = URLRequest(url: url)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("ZagStore", forHTTPHeaderField: "User-Agent")
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.timeoutInterval = 15
		URLSession.shared.dataTask(with: request) { data, response, error in
			let status = (response as? HTTPURLResponse)?.statusCode ?? -1
			let analysis = data.map { self.parseWithDiagnostic($0, app: app) } ?? ([], 0, 0)
			let items = (status == 200 && error == nil) ? analysis.0 : []
			let diagnostic = ZagGitHubHistoryDiagnostic(
				repository: repository, status: status, releases: analysis.1,
				ipaAssets: analysis.2, matchedAssets: items.count,
				error: error?.localizedDescription
			)
			self.finish(key: key, items: items, diagnostic: diagnostic)
		}.resume()
	}

	private func finish(key: String, items: [ZagGitHubHistoricalIPA], diagnostic: ZagGitHubHistoryDiagnostic) {
		lock.lock()
		cache[key] = items
		loading.remove(key)
		let callbacks = waiters.removeValue(forKey: key) ?? []
		lock.unlock()
		DispatchQueue.main.async { callbacks.forEach { $0(items, diagnostic) } }
	}

	private func cacheKey(for app: ASRepository.App) -> String {
		(app.id ?? app.name ?? "") + "|" + (app.currentDownloadUrl?.absoluteString ?? "")
	}

	private func repositoryForHistory(of app: ASRepository.App) -> String? {
		if app.currentName.localizedCaseInsensitiveContains("YTKACE") {
			return "itzzace/ytkace"
		}

		var candidates = [app.currentDownloadUrl?.absoluteString, app.currentDescription, app.localizedDescription, app.description]
			.compactMap { $0 }
		let text = candidates.joined(separator: "\n")

		// Direct GitHub URLs, including release assets.
		if let repo = githubRepository(in: text) { return repo }

		// Aggregators/proxies frequently preserve the real GitHub release path in
		// a query/path, e.g. ...apptesters-org/AppTesters_Repo/releases/download/...
		let embeddedPattern = #"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/download/"#
		if let regex = try? NSRegularExpression(pattern: embeddedPattern),
			let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
			let range = Range(match.range(at: 1), in: text) {
			return String(text[range])
		}
		return nil
	}

	private func githubRepository(in text: String) -> String? {
		let pattern = #"https?://(?:www\.)?github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"#
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
			let range = Range(match.range(at: 1), in: text) else { return nil }
		return String(text[range]).replacingOccurrences(of: ".git", with: "")
	}

	private func parseWithDiagnostic(_ data: Data, app: ASRepository.App) -> ([ZagGitHubHistoricalIPA], Int, Int) {
		guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ([], 0, 0) }
		let ipaAssets = releases.reduce(0) { count, release in
			count + ((release["assets"] as? [[String: Any]])?.filter {
				(($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true)
			}.count ?? 0)
		}
		return (parse(data, app: app), releases.count, ipaAssets)
	}

	private func parse(_ data: Data, app: ASRepository.App) -> [ZagGitHubHistoricalIPA] {
		guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
		let currentVersion = app.currentVersion
		let currentAsset = app.currentDownloadUrl?.lastPathComponent.removingPercentEncoding ?? ""
		let identityTokens = appIdentityTokens(app: app, currentAsset: currentAsset)
		var result: [ZagGitHubHistoricalIPA] = []

		for release in releases where (release["draft"] as? Bool) != true {
			let tag = release["tag_name"] as? String ?? ""
			guard let assets = release["assets"] as? [[String: Any]] else { continue }
			for asset in assets {
				guard let name = asset["name"] as? String,
					name.lowercased().hasSuffix(".ipa"),
					matchesApp(assetName: name, identityTokens: identityTokens),
					let rawURL = asset["browser_download_url"] as? String,
					let url = URL(string: rawURL),
					let version = bestVersion(in: name, currentVersion: currentVersion),
					version != currentVersion else { continue }
				result.append(.init(version: version, release: tag, downloadURL: url))
			}
		}
		var seen = Set<String>()
		return result.filter { seen.insert($0.version + "|" + $0.downloadURL.absoluteString).inserted }
	}

	private func appIdentityTokens(app: ASRepository.App, currentAsset: String) -> [String] {
		var values = [app.currentName, app.name ?? "", currentAsset]
		if let id = app.id { values.append(id) }
		return values.flatMap { tokenize($0) }.filter { $0.count >= 4 }
	}

	private func tokenize(_ value: String) -> [String] {
		value.lowercased()
			.replacingOccurrences(of: ".ipa", with: "")
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty && versions(in: $0).isEmpty }
	}

	private func matchesApp(assetName: String, identityTokens: [String]) -> Bool {
		let assetTokens = Set(tokenize(assetName))
		guard !assetTokens.isEmpty else { return false }
		return identityTokens.contains { assetTokens.contains($0) }
	}

	private func bestVersion(in value: String, currentVersion: String?) -> String? {
		let found = versions(in: value)
		guard !found.isEmpty else { return nil }
		if let currentVersion, found.contains(currentVersion) { return currentVersion }

		// YTKACE upstream assets are named like:
		// YTKACE_1.1.0_YouTube_21.38.3.ipa
		// The first dotted value is the YTKACE release; the final value is the
		// actual YouTube app version shown by the source.
		if value.localizedCaseInsensitiveContains("YTKACE"),
			value.localizedCaseInsensitiveContains("YouTube"),
			let youtubeVersion = found.last {
			return youtubeVersion
		}

		// Generic repositories commonly put the application version first.
		return found.first
	}

	private func versions(in value: String) -> [String] {
		let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+){1,3}"#)
		return regex?.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
			Range($0.range, in: value).map { String(value[$0]) }
		} ?? []
	}
}

// MARK: - Representable
struct SourceAppsTableRepresentableView: UIViewRepresentable {
	var sources: [ASRepository]
	@Binding var searchText: String
	@Binding var sortOption: SourceAppsView.SortOption
	@Binding var sortAscending: Bool
	var onSelect: (SourceAppsView.SourceAppRoute) -> Void
	
	func makeUIView(context: Context) -> UITableView {
		let tableView = UITableView(frame: .zero, style: .plain)
		tableView.backgroundColor = .clear
		tableView.delegate = context.coordinator
		tableView.dataSource = context.coordinator
		tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AppCell")
		tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "SectionHeader")
		tableView.separatorInset = UIEdgeInsets(top: 0, left: 88, bottom: 0, right: 16)
		tableView.separatorColor = UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 42.0 / 255.0, green: 42.0 / 255.0, blue: 44.0 / 255.0, alpha: 1)
				: UIColor(red: 231.0 / 255.0, green: 231.0 / 255.0, blue: 232.0 / 255.0, alpha: 1)
		}
		
		if #available(iOS 17, *) {
			tableView.allowsSelection = true
		} else {
			tableView.allowsSelection = false
		}
		
		if
			let firstSource = sources.first,
			sources.count == 1,
			let news = firstSource.news,
			!news.isEmpty
		{
			let header = UIHostingController(rootView: SourceNewsView(news: news))
			header.view.translatesAutoresizingMaskIntoConstraints = true
			header.view.backgroundColor = .clear
			let fixedHeight: CGFloat = 161
			let width = tableView.bounds.width
			header.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: fixedHeight))

			DispatchQueue.main.async {
				tableView.tableHeaderView = header.view
			}
		}
		
		tableView.alpha = 0
		
		UIView.transition(with: tableView,  duration: 0.5, options: [.transitionCrossDissolve], animations: {
			tableView.alpha = 1
		}, completion: nil)
		
		return tableView
	}
	
	func updateUIView(_ tableView: UITableView, context: Context) {
		context.coordinator.uiTableView = tableView
		
		let sourcesChanged = context.coordinator.sources != sources
		let searchChanged = context.coordinator.searchText != searchText
		let sortOptionChanged = context.coordinator.sortOption != sortOption
		let sortDirectionChanged = context.coordinator.sortAscending != sortAscending
		
		context.coordinator.sources = sources
		context.coordinator.searchText = searchText
		context.coordinator.sortOption = sortOption
		context.coordinator.sortAscending = sortAscending
		
		if sourcesChanged || searchChanged || sortOptionChanged || sortDirectionChanged {
			context.coordinator.invalidateCache()
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(
			sources: sources,
			searchText: searchText,
			sortOption: sortOption,
			sortAscending: sortAscending,
			onSelect: onSelect
		)
	}
}

// MARK: - Representable Extension: Coordinator
extension SourceAppsTableRepresentableView { class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
	var sources: [ASRepository]
	var searchText: String
	var sortOption: SourceAppsView.SortOption
	var sortAscending: Bool
	let onSelect: (SourceAppsView.SourceAppRoute) -> Void
	
	private var _groupedAppsByNameFirstLetter: [String: [(source: ASRepository, app: ASRepository.App)]] = [:]
	private var _groupedAppsByDate: [String: [(source: ASRepository, app: ASRepository.App)]] = [:]
	private var _sortedSectionTitles: [String] = []
	
	private var _cachedSortedApps: [(source: ASRepository, app: ASRepository.App)] = []
	weak var uiTableView: UITableView?
	
	private var _allAppsWithSource: [(source: ASRepository, app: ASRepository.App)] {
		sources.flatMap { source in source.apps.map { (source: source, app: $0) } }
	}
	
	private var _sortedApps: [(source: ASRepository, app: ASRepository.App)] {
		if !_cachedSortedApps.isEmpty {
			return _cachedSortedApps
		}
		_cachedSortedApps = _calculateSortedApps()
		return _cachedSortedApps
	}
	
	init(
		sources: [ASRepository],
		searchText: String,
		sortOption: SourceAppsView.SortOption,
		sortAscending: Bool,
		onSelect: @escaping (SourceAppsView.SourceAppRoute) -> Void
	) {
		self.sources = sources
		self.searchText = searchText
		self.sortOption = sortOption
		self.sortAscending = sortAscending
		self.onSelect = onSelect
		super.init()
		
		if sortOption != .default {
			invalidateCache()
		}
	}
	
	private func _calculateSortedApps() -> [(source: ASRepository, app: ASRepository.App)] {
		let filtered = _allAppsWithSource.filter {
			searchText.isEmpty ||
			($0.app.id?.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")) != nil) ||
				($0.app.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.description?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.localizedDescription?.localizedCaseInsensitiveContains(searchText) ?? false)
		}
		
		switch sortOption {
		case .default:
			_groupedAppsByDate = [:]
			_groupedAppsByNameFirstLetter = [:]
			_sortedSectionTitles = []
			return sortAscending ? filtered : filtered.reversed()
		case .date:
			let sorted = filtered.sorted {
				let d1 = $0.app.currentDate?.date ?? .distantPast
				let d2 = $1.app.currentDate?.date ?? .distantPast
				return sortAscending ? (d1 < d2) : (d1 > d2)
			}
			
			let formatter = DateFormatter()
			formatter.dateFormat = "MMMM d, yyyy"
			
			let grouped = Dictionary(grouping: sorted) {
				$0.app.currentDate?.date.stripTime() ?? .distantPast
			}
			
			let sortedDates = grouped.keys.sorted(by: { sortAscending ? $0 > $1 : $0 < $1 })
			
			_groupedAppsByDate = grouped.reduce(into: [:]) { result, pair in
				let key = formatter.string(from: pair.key)
				result[key] = pair.value
			}
			
			_sortedSectionTitles = sortedDates.map { formatter.string(from: $0) }
			return sorted
		case .name:
			let sorted = filtered.sorted {
				let n1 = $0.app.name ?? ""
				let n2 = $1.app.name ?? ""
				let comparison = n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
				return sortAscending ? comparison : !comparison
			}
			_groupedAppsByNameFirstLetter = Dictionary(grouping: sorted) {
				let first = $0.app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
				return first.range(of: "[A-Z]", options: .regularExpression) != nil ? first : "#"
			}
			_sortedSectionTitles = _groupedAppsByNameFirstLetter.keys.sorted(by: {
				if $0 == "#" { return false }
				if $1 == "#" { return true }
				return sortAscending ? $0 < $1 : $0 > $1
			})
			return sorted
		}
	}
	
	func invalidateCache() {
		_cachedSortedApps = _calculateSortedApps()
		if let tableView = uiTableView {
			UIView.transition(with: tableView, duration: 0.3, options: [.transitionCrossDissolve], animations: {
				tableView.reloadData()
			})
		}
	}
	
	// MARK: TableView
	
	func numberOfSections(in tableView: UITableView) -> Int {
		switch sortOption {
		case .default: 1
		case .name, .date: _sortedSectionTitles.count
		}
	}
	
	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		switch sortOption {
		case .default: _sortedApps.count
		case .name: _groupedAppsByNameFirstLetter[_sortedSectionTitles[section]]?.count ?? 0
		case .date: _groupedAppsByDate[_sortedSectionTitles[section]]?.count ?? 0
		}
	}
	
	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "AppCell", for: indexPath)
		let entry: (source: ASRepository, app: ASRepository.App)
		switch sortOption {
		case .default: entry = _sortedApps[indexPath.row]
		case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		}

		cell.backgroundColor = .clear
		cell.contentConfiguration = UIHostingConfiguration {
			SourceAppsCellView(source: entry.source, app: entry.app)
		}
		.background(.clear)
		return cell
	}
	
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		if #available(iOS 17, *) {
			tableView.deselectRow(at: indexPath, animated: true)
			
			let entry: (source: ASRepository, app: ASRepository.App)
			switch sortOption {
			case .default: entry = _sortedApps[indexPath.row]
			case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
			case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
			}
			
			onSelect(SourceAppsView.SourceAppRoute(source: entry.source, app: entry.app))
		}
	}
	
	func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: "SectionHeader")
		let title: String
		
		switch sortOption {
		case .default: title = .localized("%lld Apps", arguments: _sortedApps.count)
		case .name, .date: title = _sortedSectionTitles[section]
		}
		
		headerView?.backgroundView = UIView()
		headerView?.backgroundView?.backgroundColor = .clear
		headerView?.contentConfiguration = UIHostingConfiguration {
			HStack {
				Text(verbatim: title)
				Spacer()
			}
			.font(.headline)
			.padding(.vertical, 2)
		}
		.background(.clear)
		
		return headerView
	}
	
	func sectionIndexTitles(for tableView: UITableView) -> [String]? {
		sortOption == .name ? _sortedSectionTitles : nil
	}
	
	func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
		_sortedSectionTitles.firstIndex(of: title) ?? 0
	}
	
	func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
		let entry: (source: ASRepository, app: ASRepository.App)
		switch sortOption {
		case .default: entry = _sortedApps[indexPath.row]
		case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		}
		
		return UIContextMenuConfiguration(
			identifier: nil,
			previewProvider: nil
		) { _ in
			let versionsMenu = UIMenu(
				title: .localized("Copy Download URLs"),
				image: UIImage(systemName: "list.bullet"),
				children: self._contextActions(for: entry.app, with: { version in
					UIPasteboard.general.string = version?.absoluteString
				}, image: UIImage(systemName: "doc.on.clipboard"))
			)
			
				let downloadsMenu = UIMenu(
				title: .localized("Previous Versions"),
				image: UIImage(systemName: "square.and.arrow.down.on.square"),
				children: self._previousVersionElements(for: entry.app)
			)
			
			return UIMenu(children: [downloadsMenu, versionsMenu])
		}
	}
	
	// MARK: Actions
	
	private func _previousVersionElements(for app: ASRepository.App) -> [UIMenuElement] {
		let declared = (app.versions ?? []).filter { version in
			// Keep same-marketing-version historical builds when their URL/build
			// differs from the current release.
			if version.version != app.currentVersion { return true }
			if version.downloadURL != app.currentDownloadUrl { return true }
			return version.build != app.currentAppVersion?.build
		}.map { version in
			let title = version.build.map { $0.isEmpty ? version.version : "\(version.version) (\($0))" } ?? version.version
			return UIAction(title: title, image: UIImage(systemName: "arrow.down")) { _ in
				if let url = version.downloadURL {
					_ = DownloadManager.shared.startDownload(from: url, id: app.currentUniqueId)
				}
			}
		}
		if !declared.isEmpty { return declared }

		// A context menu is snapshotted when it opens. Starting an async lookup
		// here and reloading the table cannot mutate that already-open menu.
		// UIDeferredMenuElement is UIKit's async menu API: it keeps Previous
		// Versions open while GitHub history resolves, then inserts the actions.
		let deferred = UIDeferredMenuElement.uncached { completion in
			ZagGitHubHistoryResolver.shared.resolve(app) { discovered, diagnostic in
				if discovered.isEmpty {
					let errorSuffix = diagnostic.error.map { " — \($0)" } ?? ""
					completion([
						UIAction(title: "Diagnostic: \(diagnostic.repository)", attributes: [.disabled]) { _ in },
						UIAction(title: "HTTP: \(diagnostic.status)\(errorSuffix)", attributes: [.disabled]) { _ in },
						UIAction(title: "Releases: \(diagnostic.releases)", attributes: [.disabled]) { _ in },
						UIAction(title: "IPA assets: \(diagnostic.ipaAssets)", attributes: [.disabled]) { _ in },
						UIAction(title: "Matched: \(diagnostic.matchedAssets)", attributes: [.disabled]) { _ in },
						UIAction(title: .localized("No previous versions found"), attributes: [.disabled]) { _ in }
					])
					return
				}

				completion(discovered.map { item in
					let suffix = item.release.isEmpty ? "" : " — \(item.release)"
					return UIAction(
						title: "\(item.version)\(suffix)",
						image: UIImage(systemName: "arrow.down")
					) { _ in
						_ = DownloadManager.shared.startDownload(
							from: item.downloadURL,
							id: app.currentUniqueId
						)
					}
				})
			}
		}
		return [deferred]
	}

	private func _contextActions(
		for app: ASRepository.App,
		with action: @escaping (URL?) -> Void,
		image: UIImage?
	) -> [UIAction] {
		if let versions = app.versions, !versions.isEmpty {
			return versions.map { version in
				let title: String
				if let build = version.build, !build.isEmpty {
					title = "\(version.version) (\(build))"
				} else {
					title = version.version
				}

				return UIAction(
					title: title,
					image: image
				) { _ in
					action(version.downloadURL)
				}
			}
		} else {
			return [
				UIAction(
					title: app.currentVersion ?? "",
					image: image
				) { _ in
					action(app.currentDownloadUrl)
				}
			]
		}
	}
}}

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

private final class ZagGitHubHistoryResolver {
	static let shared = ZagGitHubHistoryResolver()
	private var cache: [String: [ZagGitHubHistoricalIPA]] = [:]
	private var loading = Set<String>()
	private let lock = NSLock()

	func cached(for app: ASRepository.App) -> [ZagGitHubHistoricalIPA] {
		let key = app.id ?? app.name ?? ""
		lock.lock(); defer { lock.unlock() }
		return cache[key] ?? []
	}

	func prefetch(_ app: ASRepository.App, completion: @escaping () -> Void) {
		guard let repository = upstreamRepository(for: app) else { return }
		let key = app.id ?? app.name ?? repository
		lock.lock()
		if cache[key] != nil || loading.contains(key) { lock.unlock(); return }
		loading.insert(key)
		lock.unlock()

		guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100") else { return }
		var request = URLRequest(url: url)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("ZagStore", forHTTPHeaderField: "User-Agent")
		URLSession.shared.dataTask(with: request) { data, _, _ in
			let items = data.flatMap { self.parse($0, currentVersion: app.currentVersion) } ?? []
			self.lock.lock()
			self.cache[key] = items
			self.loading.remove(key)
			self.lock.unlock()
			DispatchQueue.main.async { completion() }
		}.resume()
	}

	private func upstreamRepository(for app: ASRepository.App) -> String? {
		let text = [app.currentDescription, app.localizedDescription, app.description]
			.compactMap { $0 }.joined(separator: "\n")
		let pattern = #"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/|\)|\]|\s|$)"#
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
			let range = Range(match.range(at: 1), in: text) else { return nil }
		return String(text[range]).replacingOccurrences(of: ".git", with: "")
	}

	private func parse(_ data: Data, currentVersion: String?) -> [ZagGitHubHistoricalIPA] {
		guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
		var result: [ZagGitHubHistoricalIPA] = []
		for release in releases where (release["draft"] as? Bool) != true {
			let tag = release["tag_name"] as? String ?? ""
			guard let assets = release["assets"] as? [[String: Any]] else { continue }
			for asset in assets {
				guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".ipa"),
					let rawURL = asset["browser_download_url"] as? String, let url = URL(string: rawURL),
					let version = versions(in: name).last, version != currentVersion else { continue }
				result.append(.init(version: version, release: tag, downloadURL: url))
			}
		}
		var seen = Set<String>()
		return result.filter { seen.insert($0.version + "|" + $0.downloadURL.absoluteString).inserted }
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
		for source in sources {
			for app in source.apps where (app.versions?.count ?? 0) <= 1 {
				ZagGitHubHistoryResolver.shared.prefetch(app) { [weak tableView] in
					tableView?.reloadData()
				}
			}
		}
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
				children: self._previousVersionActions(for: entry.app)
			)
			
			return UIMenu(children: [downloadsMenu, versionsMenu])
		}
	}
	
	// MARK: Actions
	
	private func _previousVersionActions(for app: ASRepository.App) -> [UIAction] {
		let declared = (app.versions ?? []).filter { $0.version != app.currentVersion }.map { version in
			let title = version.build.map { $0.isEmpty ? version.version : "\(version.version) (\($0))" } ?? version.version
			return UIAction(title: title, image: UIImage(systemName: "arrow.down")) { _ in
				if let url = version.downloadURL {
					_ = DownloadManager.shared.startDownload(from: url, id: app.currentUniqueId)
				}
			}
		}
		if !declared.isEmpty { return declared }

		let discovered = ZagGitHubHistoryResolver.shared.cached(for: app)
		if !discovered.isEmpty {
			return discovered.map { item in
				let suffix = item.release.isEmpty ? "" : " — \(item.release)"
				return UIAction(title: "\(item.version)\(suffix)", image: UIImage(systemName: "arrow.down")) { _ in
					_ = DownloadManager.shared.startDownload(from: item.downloadURL, id: app.currentUniqueId)
				}
			}
		}

		return [UIAction(title: .localized("No previous versions found"), attributes: [.disabled]) { _ in }]
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

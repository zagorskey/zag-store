//
//  SourceAppsDetailView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import NukeUI

// MARK: - SourceAppsDetailView
struct SourceAppsDetailView: View {
	@Environment(\.scenePhase) private var scenePhase
	@ObservedObject var downloadManager = DownloadManager.shared
	@ObservedObject private var pairingCore = ZagRPPairingCore.shared
	@AppStorage("ZagStore.showInternalMetadata") private var _showInternalMetadata = false
	@State private var _downloadProgress: Double = 0
	@State var cancellable: AnyCancellable? // Combine
	@State private var _isScreenshotPreviewPresented: Bool = false
	@State private var _selectedScreenshotIndex: Int = 0
	@State private var _promotionalHeaderImage: UIImage?
	@State private var _verifiedFeaturedHero: ZagAppDetailHeaderHero?
	@State private var _catalogueScreenshotURLs: [URL] = []
	@State private var _galleryThumbnailImages: [URL: UIImage] = [:]

	private var _galleryScreenshotURLs: [URL] {
		let repositoryImages = app.currentScreenshotURLs
		return repositoryImages.isEmpty ? _catalogueScreenshotURLs : repositoryImages
	}

	// Genuine promotional artwork has a separate source from gallery screenshots.
	// Verified gameplay/screenshots are a fallback only when no banner exists.
	private var _headerArtworkKey: String {
		app.currentUniqueId + "|promotional|" +
			(app.currentPromotionalArtworkURL?.absoluteString ?? "")
	}
	
	var currentDownload: Download? {
		downloadManager.getDownload(by: app.currentUniqueId)
	}
	
	var source: ASRepository
	var app: ASRepository.App
	var prefetchedFeaturedHero: ZagAppDetailHeaderHero? = nil
	
	var body: some View {
		_detailPresented
	}

	private var _detailScroll: some View {
		ScrollView {
			if #available(iOS 18, *) {
				_header().flexibleHeaderContent()
			}
			_detailContent
				.padding([.horizontal, .bottom])
				.padding(.top, {
					if #available(iOS 18, *) { return CGFloat(8) }
					return CGFloat(0)
				}())
		}
		.flexibleHeaderScrollView()
		.shouldSetInset()
	}

	private var _detailWithToolbar: some View {
		_detailScroll
			.toolbar {
				ToolbarItemGroup(placement: .topBarTrailing) {
					Button {
						let sharedString = """
						\(app.currentName) - \(app.currentVersion ?? "0")
						\(app.currentDescription ?? .localized("An awesome application"))
						---
						\(source.website?.absoluteString ?? source.name ?? "")
						"""
						UIActivityViewController.show(activityItems: [sharedString])
					} label: {
						Image(systemName: "square.and.arrow.up")
					}
					ZagProfileToolbarButton()
						.tint(.primary)
						.padding(.trailing, -2)
				}
			}
			.onAppear(perform: _refreshInstalledState)
	}

	private var _detailWithTasks: some View {
		_detailWithToolbar
			.task(id: _screenshotTaskKey) {
				await _loadScreenshots()
			}
			.task(id: _catalogueTaskKey) {
				await _loadCatalogue()
			}
			.task(id: _headerArtworkKey) {
				await _loadPromotionalHeader()
			}
			.task(id: _featuredArtworkTaskKey) {
				await _loadVerifiedFeaturedArtwork()
			}
	}

	private var _detailPresented: some View {
		_detailWithTasks
			.onChange(of: scenePhase) { phase in
				if phase == .active { _refreshInstalledState() }
			}
			.fullScreenCover(isPresented: $_isScreenshotPreviewPresented) {
				if !_galleryScreenshotURLs.isEmpty {
					ScreenshotPreviewView(
						screenshotURLs: _galleryScreenshotURLs,
						initialIndex: _selectedScreenshotIndex,
						thumbnailImages: _galleryThumbnailImages
					)
				}
			}
	}

	private var _screenshotTaskKey: String {
		app.currentUniqueId + "|screenshots|" + _galleryScreenshotURLs.map(\.absoluteString).joined(separator: "|")
	}

	private var _catalogueTaskKey: String {
		app.currentUniqueId + "|gallery|" + app.currentName
	}

	// Restore the Games storefront's verified artwork pipeline for apps
	// without published banners. This key also observes Apple gallery updates.
	private var _featuredArtworkTaskKey: String {
		app.currentUniqueId + "|featured|" +
			_galleryScreenshotURLs.map(\.absoluteString).joined(separator: "|")
	}

	@MainActor
	private func _loadScreenshots() async {
		// Keep the existing clear-on-app-change behavior. Prioritize
		// visible thumbnails and retain only 1200px-decoded images here;
		// compressed full-resolution bytes stay in the shared cache.
		_galleryThumbnailImages = [:]
		let urls = Array(_galleryScreenshotURLs.prefix(12))
		guard !urls.isEmpty else { return }
		let loadStart = ZagPerformanceMonitor.now()
		for batchStart in stride(from: 0, to: urls.count, by: 3) {
			guard !Task.isCancelled else { return }
			let batchEnd = min(batchStart + 3, urls.count)
			await _loadScreenshotBatch(Array(urls[batchStart..<batchEnd]))
			guard !Task.isCancelled else { return }
			if batchStart == 0 {
				ZagPerformanceMonitor.shared.record(
					.galleryFirst,
					since: loadStart,
					result: "\(_galleryThumbnailImages.count)/\(min(3, urls.count))"
				)
			}
		}
		ZagPerformanceMonitor.shared.record(
			.galleryComplete,
			since: loadStart,
			result: "\(_galleryThumbnailImages.count)/\(urls.count)"
		)
	}

	@MainActor
	private func _loadScreenshotBatch(_ urls: [URL]) async {
		await withTaskGroup(of: (URL, UIImage?).self) { group in
			for url in urls {
				group.addTask {
					let bytes = await ZagFeaturedImageCache.shared.load(url)
					return (url, bytes.flatMap { ZagScreenshotThumbnailDecoder.decode($0.data) })
				}
			}
			for await (url, image) in group {
				guard !Task.isCancelled else { return }
				if let image { _galleryThumbnailImages[url] = image }
			}
		}
	}

	@MainActor
	private func _loadCatalogue() async {
		_catalogueScreenshotURLs = []
		guard app.currentScreenshotURLs.isEmpty else { return }
		let started = ZagPerformanceMonitor.now()
		let catalogue = try? await ZagGameArtworkClient.shared.lookup(
			bundleID: app.id ?? "", name: app.currentName
		)
		guard !Task.isCancelled else { return }
		_catalogueScreenshotURLs = catalogue?.artworkURLs ?? []
		ZagPerformanceMonitor.shared.record(
			.catalogueLookup,
			since: started,
			result: _catalogueScreenshotURLs.isEmpty ? "unavailable" : "found"
		)
	}

	@MainActor
	private func _loadPromotionalHeader() async {
		_promotionalHeaderImage = nil
		let started = ZagPerformanceMonitor.now()
		let verified = await ZagPromotionalArtworkResolver.shared.resolve(
			bundleID: app.id,
			name: app.currentName,
			declaredURL: app.currentPromotionalArtworkURL,
			screenshotURLs: _galleryScreenshotURLs
		)
		guard !Task.isCancelled else { return }
		_promotionalHeaderImage = verified.flatMap { UIImage(data: $0.data) }
		ZagPerformanceMonitor.shared.record(
			.promotionalArtwork,
			since: started,
			result: _promotionalHeaderImage == nil ? "unavailable" : "verified"
		)
	}

	@MainActor
	private func _loadVerifiedFeaturedArtwork() async {
		// Games Featured already verified the artwork; avoid fetching it twice.
		guard prefetchedFeaturedHero == nil, !_galleryScreenshotURLs.isEmpty else { return }
		let started = ZagPerformanceMonitor.now()
		let verified = await ZagFeaturedArtworkResolver.shared.resolve(
			bundleID: app.id,
			name: app.currentName,
			repositoryScreenshots: _galleryScreenshotURLs
		)
		guard !Task.isCancelled else { return }
		_verifiedFeaturedHero = verified.flatMap { ZagAppDetailHeaderHero($0) }
		ZagPerformanceMonitor.shared.record(
			.featuredArtwork,
			since: started,
			result: _verifiedFeaturedHero == nil ? "unavailable" : "verified"
		)
	}

	// Keep the large detail-page builder separate from the scroll-view modifiers.
	private var _detailContent: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				if let iconURL = app.iconURL {
					LazyImage(url: iconURL) { state in
						if let image = state.image {
							image.appIconStyle(size: 111, isCircle: false)
						} else {
							standardIcon
						}
					}
				} else {
					standardIcon
				}

				VStack(alignment: .leading, spacing: 2) {
					Text(app.currentName)
						.font(.title2)
						.fontWeight(.semibold)
						.foregroundColor(.primary)
					Text(app.currentDescription ?? .localized("An awesome application"))
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					Spacer()
					
					DownloadButtonView(app: app, source: source)
				}
				.lineLimit(2)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			
			Divider()
			_infoPills(app: app)
			Divider()
                
			if !_galleryScreenshotURLs.isEmpty {
				NBSection(.localized("Screenshots")) {
					_screenshots(screenshotURLs: _galleryScreenshotURLs)
				}
                    
				Divider()
			}
			
			if
				let currentVer = app.currentVersion,
				let whatsNewDesc = app.currentAppVersion?.localizedDescription
			{
				NBSection(.localized("What's New")) {
					AppVersionInfo(
						version: currentVer,
						date: app.currentDate?.date,
						description: whatsNewDesc
					)
					if let versions = app.versions {
						NavigationLink(
							destination: VersionHistoryView(app: app, versions: versions)
								.navigationTitle(.localized("Version History"))
								.navigationBarTitleDisplayMode(.large)
						) {
							Text(.localized("Version History"))
						}
					}
				}
				
				Divider()
			}
			
			if let appDesc = app.localizedDescription {
				NBSection(.localized("Description")) {
					VStack(alignment: .leading, spacing: 2) {
						ExpandableText(text: appDesc, lineLimit: 3)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				
				Divider()
			}
                
			_informationSection
			_metadataSection
			_permissionsSection
		}
	}

	@ViewBuilder
	private var _informationSection: some View {
		NBSection(.localized("Information")) {
			VStack(spacing: 12) {
				if let sourceName = source.name {
					_infoRow(title: .localized("Source"), value: sourceName)
				}
                        
				if let developer = app.developer {
					_infoRow(title: .localized("Developer"), value: developer)
				}
				
				if let size = app.size {
					_infoRow(title: .localized("Size"), value: size.formattedByteCount)
				}
				
				if let category = app.category {
					_infoRow(title: .localized("Category"), value: category.capitalized)
				}
				
				if let version = app.currentVersion {
					_infoRow(title: .localized("Version"), value: version)
				}

				if
					let bundleID = app.id,
					let installed = pairingCore.installedAppInfo(bundleID: bundleID)
				{
					if let installedVariant = _installedVariantLabel(bundleID: bundleID) {
						_infoRow(
							title: .localized("Installed Variant"),
							value: installedVariant
						)
					}

					let installedValue = installed.build.isEmpty
						? installed.version
						: "\(installed.version) (\(installed.build))"
					_infoRow(
						title: .localized("Installed"),
						value: installedValue
					)
				}
				
				if let date = app.currentDate?.date {
					_infoRow(title: .localized("Updated"), value: DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
				}
				
				if let bundleId = app.id {
					_infoRow(title: .localized("Identifier"), value: bundleId)
				}
			}
		}
		
	}

	@ViewBuilder
	private var _metadataSection: some View {

		if _showInternalMetadata {
			Divider()
			NBSection("Developer Metadata") {
				VStack(spacing: 12) {
					_infoRow(title: "Bundle ID", value: app.id ?? "Unknown")
					_infoRow(title: "Unique ID", value: app.currentUniqueId)
					_infoRow(title: "Variant Identity", value: UpdateManager.variantIdentity(for: app))
					_infoRow(title: "Repository ID", value: source.id ?? "Unknown")
					_infoRow(title: "Tracked Repository", value: _trackedRepositoryValue())
					_infoRow(title: "Tracked App Identity", value: _trackedAppIdentityValue())
					_infoRow(title: "Tracked Variant", value: _trackedVariantValue())
					_infoRow(title: "Device Inventory", value: _deviceInventoryValue())
					_infoRow(title: "Download Host", value: app.currentDownloadUrl?.host ?? "Unknown")
				}
			}
		}

	}

	@ViewBuilder
	private var _permissionsSection: some View {

		if let appPermissions = app.appPermissions {
			NBSection(.localized("Permissions")) {
				Group {
					if let entitlements = appPermissions.entitlements {
						NBTitleWithSubtitleView(
							title: .localized("Entitlements"),
							subtitle: entitlements.map(\.name).joined(separator: "\n")
						)
					} else {
						Text(.localized("No Entitlements listed."))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
					if let privacyItems = appPermissions.privacy {
						ForEach(privacyItems, id: \.self) { item in
							NBTitleWithSubtitleView(
								title: item.name,
								subtitle: item.usageDescription
							)
						}
					} else {
						Text(.localized("No Privacy Permissions listed."))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding()
				.background(
					RoundedRectangle(cornerRadius: 18, style: .continuous)
						.fill(Color(.quaternarySystemFill))
				)
			}
		}
	}

	var standardIcon: some View {
		Image("App_Unknown").appIconStyle(size: 111, isCircle: false)
	}
	
	var standardHeader: some View {
		Image("App_Unknown")
			.resizable()
			.aspectRatio(contentMode: .fill)
			.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
			.clipped()
	}
}

private extension SourceAppsDetailView {
	func _trackedRepositoryValue() -> String {
		guard let bundleID = app.id else { return "None" }
		let values = UserDefaults.standard.dictionary(forKey: "zagStore.repositoryOrigins") as? [String: String] ?? [:]
		return values[bundleID] ?? "None"
	}

	func _trackedAppIdentityValue() -> String {
		guard let bundleID = app.id else { return "None" }
		let values = UserDefaults.standard.dictionary(forKey: "zagStore.repositoryAppOrigins") as? [String: String] ?? [:]
		return values[bundleID] ?? "None"
	}

	func _trackedVariantValue() -> String {
		guard let bundleID = app.id else { return "None" }
		let values = UserDefaults.standard.dictionary(forKey: "zagStore.repositoryVariantOrigins") as? [String: String] ?? [:]
		return values[bundleID] ?? "None"
	}

	func _deviceInventoryValue() -> String {
		guard let bundleID = app.id else { return "Unknown" }
		guard let installed = pairingCore.installedAppInfo(bundleID: bundleID) else {
			return "Not present"
		}
		return installed.build.isEmpty
			? "Installed • \(installed.version)"
			: "Installed • \(installed.version) (\(installed.build))"
	}

	func _installedVariantLabel(bundleID: String) -> String? {
		let defaults = UserDefaults.standard
		let variantOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryVariantOrigins"
		) as? [String: String] ?? [:]
		guard variantOrigins[bundleID] != nil else { return nil }

		let appOrigins = defaults.dictionary(
			forKey: "zagStore.repositoryAppOrigins"
		) as? [String: String] ?? [:]
		guard let trackedName = appOrigins[bundleID], !trackedName.isEmpty else {
			return .localized("Tracked Variant")
		}

		// Prefer the human-readable variant description from the currently
		// opened repository entry when it is the tracked lineage.
		if UpdateManager.variantIdentity(for: app) == variantOrigins[bundleID] {
			let description =
				app.currentAppVersion?.localizedDescription ??
				app.versionDescription ??
				app.currentDescription
			if let description, !description.isEmpty {
				return "\(trackedName) — \(description)"
			}
		}
		return trackedName
	}

	func _refreshInstalledState() {
		guard
			pairingCore.pairingFileExists,
			pairingCore.installedAppsState != .refreshing
		else {
			return
		}
		try? pairingCore.refreshInstalledApps()
	}
}

// MARK: - Shared verified screenshot hero for all app information pages
// Keep decoded UIImages in view state so scrolling never repeatedly decodes
// multi-megabyte screenshots. Only the verified artwork pipeline creates these.
enum ZagAppDetailHeaderHero {
	case landscape(UIImage)
	case portraits([UIImage])
	case landscapeStrips([UIImage])

	init?(_ artwork: ZagVerifiedFeaturedArtwork) {
		let images = artwork.images.compactMap { UIImage(data: $0.data) }
		guard let first = images.first else { return nil }
		switch artwork.layout {
		case .landscape:
			self = .landscape(first)
		case .portraits:
			self = .portraits(images)
		case .landscapeStrips:
			self = .landscapeStrips(images)
		}
	}
}

struct ZagAppDetailHeaderImage: View {
	let hero: ZagAppDetailHeaderHero

	var body: some View {
		GeometryReader { geometry in
			let width = geometry.size.width
			let height = geometry.size.height

			ZStack {
				Color.black
				switch hero {
				case .landscape(let image):
					// True landscape screenshot, full bleed and sharp.
					Image(uiImage: image)
						.resizable()
						.scaledToFill()
						.frame(width: width, height: height)
						.clipped()

				case .portraits(let images):
					// Use actual portrait screenshots side by side. Never
					// repeat a single screenshot or stretch it full-width.
					HStack(spacing: 3) {
						ForEach(images.indices, id: \.self) { index in
							Image(uiImage: images[index])
								.resizable()
								.scaledToFill()
								.frame(
									width: images.count == 1 ? width * 0.53 :
										(width - CGFloat(images.count - 1) * 3) / CGFloat(images.count),
									height: height
								)
								.clipped()
						}
					}
					.frame(width: width, height: height)
					.clipped()

				case .landscapeStrips(let images):
					// Small landscape shots stay in compact panels to avoid
					// pixelated full-bleed upscaling.
					VStack(spacing: 3) {
						ForEach(images.indices, id: \.self) { index in
							Image(uiImage: images[index])
								.resizable()
								.scaledToFill()
								.frame(
									width: images.count == 1 ? width * 0.80 : width,
									height: images.count == 1 ? height * 0.72 :
										(height - CGFloat(images.count - 1) * 3) / CGFloat(images.count)
								)
								.clipped()
						}
					}
					.frame(width: width, height: height)
					.clipped()
				}
			}
			.frame(width: width, height: height)
			.clipped()
			.overlay {
				// Light nav-bar contrast without obscuring the actual image.
				LinearGradient(
					stops: [
						.init(color: .black.opacity(0.42), location: 0),
						.init(color: .clear, location: 0.45),
						.init(color: .black.opacity(0.18), location: 1)
					],
					startPoint: .top,
					endPoint: .bottom
				)
				.allowsHitTesting(false)
			}
		}
		.accessibilityHidden(true)
	}
}

// MARK: - SourceAppsDetailView (Extension): Builders
extension SourceAppsDetailView {
	@available(iOS 18.0, *)
	@ViewBuilder
	private func _header() -> some View {
		if let image = _promotionalHeaderImage {
			// Independent publisher banner has priority over gallery media.
			ZagPromotionalBannerView(image: image)
		} else if let featured = _verifiedFeaturedHero ?? prefetchedFeaturedHero {
			// Match the working Games artwork selection and display layout
			// whenever independent promotional art cannot be found.
			ZagAppDetailHeaderImage(hero: featured)
		} else {
			// No verified imagery: keep a branded header rather than a blank void.
			ZagSynthesizedAppHeroView(
				appName: app.currentName,
				iconURL: app.iconURL,
				screenshots: [],
				tint: source.tintColor ?? .accentColor
			)
		}
	}
	
	@ViewBuilder
	private func _infoPills(app: ASRepository.App) -> some View {
		let pillItems = _buildPills(from: app)
		HStack(spacing: 6) {
			ForEach(pillItems.indices, id: \.hashValue) { index in
				let pill = pillItems[index]
				NBPillView(
					title: pill.title,
					icon: pill.icon,
					color: pill.color,
					index: index,
					count: pillItems.count
				)
			}
		}
	}
	
	private func _buildPills(from app: ASRepository.App) -> [NBPillItem] {
		var pills: [NBPillItem] = []
		
		if let version = app.currentVersion {
			pills.append(NBPillItem(title: version, icon: "tag", color: Color.accentColor))
		}
		
		if let size = app.size {
			pills.append(NBPillItem(title: size.formattedByteCount, icon: "archivebox", color: .secondary))
		}
		
		return pills
	}
	
	@ViewBuilder
	private func _infoRow(title: String, value: String) -> some View {
		LabeledContent(title, value: value)
		Divider()
	}
	
	@ViewBuilder
	private func _screenshots(screenshotURLs: [URL]) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			LazyHStack(spacing: 12) {
				ForEach(screenshotURLs.indices, id: \.self) { index in
					let url = screenshotURLs[index]
					if let image = _galleryThumbnailImages[url] {
						Image(uiImage: image)
							.resizable()
								.aspectRatio(contentMode: .fit)
								.frame(
									maxWidth: UIScreen.main.bounds.width - 32,
									maxHeight: 400
								)
								.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
								.overlay {
									RoundedRectangle(cornerRadius: 16, style: .continuous)
										.strokeBorder(.gray.opacity(0.3), lineWidth: 1)
								}
								.onTapGesture {
									_selectedScreenshotIndex = index
									_isScreenshotPreviewPresented = true
								}
					} else {
						LazyImage(url: url) { state in
							if let image = state.image {
								image.resizable()
									.aspectRatio(contentMode: .fit)
									.frame(maxWidth: UIScreen.main.bounds.width - 32, maxHeight: 400)
									.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
									.onTapGesture {
										_selectedScreenshotIndex = index
										_isScreenshotPreviewPresented = true
									}
							}
						}
					}
				}
			}
			.padding(.horizontal)
			.compatScrollTargetLayout()
		}
		.compatScrollTargetBehavior()
		.modifier(ZagGalleryScrollMetricsModifier())
		.padding(.horizontal, -16)
	}
}

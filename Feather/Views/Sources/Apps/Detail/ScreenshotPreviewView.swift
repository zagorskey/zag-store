//
//  ScreenshotPreviewView.swift
//  Feather
//
//  Created by Nagata Asami on 2/8/25.
//

import SwiftUI

struct ScreenshotPreviewView: View {
	@Environment(\.dismiss) var dismiss
	@State private var currentIndex: Int
	@State private var loadedPreviewImages: [URL: UIImage]
    
	let screenshotURLs: [URL]
	let thumbnailImages: [URL: UIImage]
    
	init(
		screenshotURLs: [URL],
		initialIndex: Int = 0,
		thumbnailImages: [URL: UIImage] = [:]
	) {
		self.screenshotURLs = screenshotURLs
		self.thumbnailImages = thumbnailImages
		self._loadedPreviewImages = State(initialValue: [:])
		self._currentIndex = State(initialValue: initialIndex)
	}
    
	var body: some View {
		NavigationStack {
			_imageScrollView()
				.task(id: currentIndex) {
					await _loadCurrentAndAdjacentScreenshots()
				}
				.toolbar {
					ToolbarItem(placement: .topBarTrailing) {
						if #available(iOS 26.0, *) {
							Button(role: .close) { dismiss() }
						} else {
							Button(.localized("Close"), role: .cancel) { dismiss() }
						}
					}
					ToolbarItem(placement: .topBarLeading) {
						if #available(iOS 26.0, *) {
							_counterLabel
						} else {
							_counterLabel
								.background(
									Capsule().fill(.ultraThinMaterial)
								)
						}
					}
				}
		}
	}
	// Reserve the whole counter's width inside the navigation toolbar.
	// iOS 26/27 can otherwise compress a flexible Text into just "3".
	private var _counterLabel: some View {
		Text(verbatim: "\(currentIndex + 1) / \(screenshotURLs.count)")
			.font(.subheadline.weight(.medium))
			.monospacedDigit()
			.lineLimit(1)
			.fixedSize(horizontal: true, vertical: false)
			.frame(width: 92, height: 36)
			.accessibilityLabel("Screenshot \(currentIndex + 1) of \(screenshotURLs.count)")
	}
	// The gallery already supplies a downsampled thumbnail for immediate
	// display. Do not decode or change image state during an interactive swipe:
	// wait for the page to settle, then decode a screen-sized rendition on a
	// background executor. This avoids main-thread UIImage(data:) decoding.
	@MainActor
	private func _loadCurrentAndAdjacentScreenshots() async {
		guard screenshotURLs.indices.contains(currentIndex) else { return }
		let selectedIndex = currentIndex
		let selectedURL = screenshotURLs[selectedIndex]

		// A swipe changes currentIndex and cancels the previous .task. Do not
		// start disk access or publish new UIImages during that transition.
		try? await Task.sleep(for: .milliseconds(220))
		guard !Task.isCancelled, currentIndex == selectedIndex else { return }

		let nearbyIndices = [selectedIndex, selectedIndex - 1, selectedIndex + 1]
			.filter { screenshotURLs.indices.contains($0) }
		let nearbyURLs = Set(nearbyIndices.map { screenshotURLs[$0] })

		// At most three screen-sized bitmaps are retained at once.
		loadedPreviewImages = loadedPreviewImages.filter { nearbyURLs.contains($0.key) }

		let started = ZagPerformanceMonitor.now()
		let wasReady = loadedPreviewImages[selectedURL] != nil
		if !wasReady {
			if let image = await _decodePreview(selectedURL),
			   !Task.isCancelled, currentIndex == selectedIndex {
				loadedPreviewImages[selectedURL] = image
			}
		}
		guard !Task.isCancelled, currentIndex == selectedIndex else { return }
		ZagPerformanceMonitor.shared.record(
			.previewFullResolution,
			since: started,
			result: loadedPreviewImages[selectedURL] == nil
				? "unavailable" : (wasReady ? "prefetched" : "loaded")
		)

		// Only after the selected frame is ready do we prepare neighbours.
		// The shared byte cache coalesces requests with the detail-page gallery.
		for index in [selectedIndex + 1, selectedIndex - 1]
			where screenshotURLs.indices.contains(index) {
			guard !Task.isCancelled, currentIndex == selectedIndex else { return }
			let url = screenshotURLs[index]
			if loadedPreviewImages[url] != nil { continue }
			if let image = await _decodePreview(url),
			   !Task.isCancelled, currentIndex == selectedIndex {
				loadedPreviewImages[url] = image
			}
		}
	}

	// ImageIO forces the bitmap to be decoded before the UIImage reaches
	// SwiftUI. A 2200px maximum still looks sharp on a Pro Max display
	// without holding several original 4K+ screenshot buffers in memory.
	private func _decodePreview(_ url: URL) async -> UIImage? {
		guard let bytes = await ZagFeaturedImageCache.shared.load(url),
		      !Task.isCancelled else { return nil }
		let data = bytes.data
		return await Task.detached(priority: .utility) {
			ZagScreenshotThumbnailDecoder.decode(data, maxPixelSize: 2200)
		}.value
	}

}

extension ScreenshotPreviewView {
	private func _imageScrollView() -> some View {
		ZagScreenshotPagerView(
			selectedIndex: $currentIndex,
			urls: screenshotURLs,
			thumbnails: thumbnailImages,
			previews: loadedPreviewImages
		)
		.ignoresSafeArea(edges: .horizontal)
	}
}

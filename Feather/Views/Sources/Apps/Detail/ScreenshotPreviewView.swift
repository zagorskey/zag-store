//
//  ScreenshotPreviewView.swift
//  Feather
//
//  Created by Nagata Asami on 2/8/25.
//

import SwiftUI
import NukeUI

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
	// When the user jumps to a screenshot before the background gallery pass
	// reaches it, request its original high-resolution bytes immediately.
	// Both views use the same coalescing image cache, so there is no duplicate
	// network transfer. Prefetch the adjacent image for a smoother swipe.
	@MainActor
	private func _loadCurrentAndAdjacentScreenshots() async {
		guard screenshotURLs.indices.contains(currentIndex) else { return }
		let started = ZagPerformanceMonitor.now()
		let currentURL = screenshotURLs[currentIndex]
		let wasPreloaded = loadedPreviewImages[currentURL] != nil
		let indices = [currentIndex, currentIndex + 1, currentIndex - 1]
			.filter { screenshotURLs.indices.contains($0) }

		// At most three decoded full-resolution images live in preview memory.
		// A previously seen image can be restored quickly from the shared cache.
		let nearbyURLs = Set(indices.map { screenshotURLs[$0] })
		loadedPreviewImages = loadedPreviewImages.filter {
			nearbyURLs.contains($0.key)
		}

		for index in indices {
			guard !Task.isCancelled else { return }
			let url = screenshotURLs[index]
			if loadedPreviewImages[url] != nil { continue }
			guard let bytes = await ZagFeaturedImageCache.shared.load(url),
				!Task.isCancelled,
				let image = UIImage(data: bytes.data) else { continue }
			loadedPreviewImages[url] = image
		}
		guard !Task.isCancelled else { return }
		ZagPerformanceMonitor.shared.record(
			.previewFullResolution,
			since: started,
			result: loadedPreviewImages[currentURL] == nil
				? "unavailable" : (wasPreloaded ? "prefetched" : "loaded")
		)

	}

}

extension ScreenshotPreviewView {
	@ViewBuilder
	private func _imageScrollView() -> some View {
		TabView(selection: $currentIndex) {
			ForEach(screenshotURLs.indices, id: \.self) { index in
				Group {
					if let highResolution = loadedPreviewImages[screenshotURLs[index]] {
						Image(uiImage: highResolution)
							.resizable()
							.aspectRatio(contentMode: .fit)
					} else if let thumbnail = thumbnailImages[screenshotURLs[index]] {
						Image(uiImage: thumbnail)
							.resizable()
							.aspectRatio(contentMode: .fit)
					} else {
						LazyImage(url: screenshotURLs[index]) { state in
							if let image = state.image {
								image.resizable().aspectRatio(contentMode: .fit)
							}
						}
					}
				}
				.clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
				.overlay {
					RoundedRectangle(cornerRadius: 32, style: .continuous)
						.strokeBorder(.gray.opacity(0.3), lineWidth: 1)
				}
				.tag(index)
				.padding(.horizontal)
			}
		}
		.tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

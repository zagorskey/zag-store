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
    
	let screenshotURLs: [URL]
	let highResolutionImages: [URL: UIImage]
    
	init(
		screenshotURLs: [URL],
		initialIndex: Int = 0,
		highResolutionImages: [URL: UIImage] = [:]
	) {
		self.screenshotURLs = screenshotURLs
		self.highResolutionImages = highResolutionImages
		self._currentIndex = State(initialValue: initialIndex)
	}
    
	var body: some View {
		NavigationStack {
			_imageScrollView()
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
}

extension ScreenshotPreviewView {
	@ViewBuilder
	private func _imageScrollView() -> some View {
		TabView(selection: $currentIndex) {
			ForEach(screenshotURLs.indices, id: \.self) { index in
				Group {
					if let highResolution = highResolutionImages[screenshotURLs[index]] {
						Image(uiImage: highResolution)
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

//
//  ScreenshotPreviewView.swift
//  Feather
//
//  Keep fullscreen paging deliberately lightweight: the detail gallery
//  already decoded its thumbnails. Replacing them mid-swipe with large
//  bitmaps was causing unnecessary view updates and image uploads.
//

import SwiftUI

struct ScreenshotPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    let screenshotURLs: [URL]
    let thumbnailImages: [URL: UIImage]

    init(
        screenshotURLs: [URL],
        initialIndex: Int = 0,
        thumbnailImages: [URL: UIImage] = [:]
    ) {
        self.screenshotURLs = screenshotURLs
        self.thumbnailImages = thumbnailImages
        self._currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        NavigationStack {
            ZagScreenshotPagerView(
                selectedIndex: $currentIndex,
                urls: screenshotURLs,
                thumbnails: thumbnailImages
            )
            .ignoresSafeArea(edges: .horizontal)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if #available(iOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button(.localized("Close"), role: .cancel) { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Text(verbatim: "\(currentIndex + 1) / \(screenshotURLs.count)")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 92, height: 36)
                        .accessibilityLabel(
                            "Screenshot \(currentIndex + 1) of \(screenshotURLs.count)"
                        )
                }
            }
        }
    }
}

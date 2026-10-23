//
//  ZagScreenshotThumbnailDecoder.swift
//  Feather
//
//  Downsample repository screenshots without decoding their full pixel buffers.
//  The original verified bytes remain available in ZagFeaturedImageCache for
//  full-screen viewing; only gallery-sized UIImages are retained in the page.
//

import Foundation
import ImageIO
import UIKit

enum ZagScreenshotThumbnailDecoder {
    /// 1200px covers the 400pt gallery height at 3x display scale.
    /// All decoding happens in the caller's background task.
    static func decode(_ data: Data, maxPixelSize: Int = 1200) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }

        return UIImage(cgImage: image)
    }
}

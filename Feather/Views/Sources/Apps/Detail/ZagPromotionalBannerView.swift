//
//  ZagPromotionalBannerView.swift
//  Feather
//
//  Displays a real landscape marketing asset independently of the gallery.
//  Wide banners fill the viewport; a measured crop avoids letterboxing.
//

import SwiftUI

struct ZagPromotionalBannerView: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                Color.black

                // Real banners fill the full header even when the publisher
                // supplied an unusually wide asset. Prefer a deliberate crop
                // over an empty grey/black letterbox underneath the banner.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.32), location: 0),
                        .init(color: .clear, location: 0.33),
                        .init(color: .black.opacity(0.10), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

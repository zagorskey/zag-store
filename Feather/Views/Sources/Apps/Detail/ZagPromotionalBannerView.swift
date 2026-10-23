//
//  ZagPromotionalBannerView.swift
//  Feather
//
//  Displays a real landscape marketing asset independently of the gallery.
//  Extra-wide social banners are fit without cropping their branding.
//

import SwiftUI

struct ZagPromotionalBannerView: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let imageRatio = image.size.height > 0
                ? image.size.width / image.size.height : CGFloat(1.8)

            ZStack {
                Color.black

                if imageRatio > 2.4 {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .blur(radius: 34)
                        .overlay(Color.black.opacity(0.32))
                        .clipped()

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: width, height: height)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                }

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

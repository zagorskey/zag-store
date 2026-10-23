//
//  ZagSynthesizedAppHeroView.swift
//  Feather
//
//  Editorial fallback when no independent promotional artwork is available.
//  Never duplicates the gallery or the app icon shown below the header.
//

import SwiftUI

struct ZagSynthesizedAppHeroView: View {
    let appName: String
    let iconURL: URL?
    let screenshots: [UIImage]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                _backdrop

                if !screenshots.isEmpty {
                    _screenshotComposition(in: geometry.size)
                }

                // Maintain contrast around the title and the navigation bar.
                LinearGradient(
                    colors: [
                        .black.opacity(0.78),
                        .black.opacity(0.22),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .allowsHitTesting(false)

                if screenshots.isEmpty {
                    Text(String(appName.prefix(1)).uppercased())
                        .font(.system(size: 220, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.09))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .offset(x: 30, y: 20)
                }

                _identity
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    private var _backdrop: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    tint.opacity(0.50),
                    tint.opacity(0.20),
                    Color.black.opacity(0.85),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [tint.opacity(0.27), .clear],
                center: .trailing,
                startRadius: 8,
                endRadius: 290
            )
        }
    }

    private func _screenshotComposition(in size: CGSize) -> some View {
        let width = min(size.width * 0.41, 195)
        let height = max(size.height * 0.95, 140)

        return HStack(alignment: .center, spacing: -24) {
            if screenshots.count > 1 {
                _screenPanel(
                    screenshots[1],
                    width: width * 0.92,
                    height: height * 0.89
                )
                .rotationEffect(.degrees(7))
                .offset(x: 12, y: 34)
            }

            _screenPanel(
                screenshots[0],
                width: width,
                height: height
            )
            .rotationEffect(.degrees(-6))
            .offset(y: 12)
        }
        .frame(width: size.width, height: size.height, alignment: .trailing)
        .offset(x: 14, y: size.height * 0.09)
    }

    private func _screenPanel(_ image: UIImage, width: CGFloat, height: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: width - 8, height: height - 8)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.90))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.48), radius: 20, y: 10)
    }

    private var _identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)

            Text(appName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: 180, alignment: .leading)
                .shadow(color: .black.opacity(0.35), radius: 5)
        }
        .padding(.leading, 26)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

}

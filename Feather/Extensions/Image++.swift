//
//  Image+appIconStyle.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI

extension Image {
    /// Shared App Store-style icon finish. The original image-loading and
    /// caching paths remain untouched; only the final on-screen edge is styled.
    func appIconStyle(
        size: CGFloat = 56,
        lineWidth: CGFloat = 1,
        isCircle: Bool = false,
        background: Color = .clear
    ) -> some View {
        var multiplier: CGFloat = 0.2337
        if #available(iOS 26.0, *) {
            multiplier = 0.2677
        }

        let radius = isCircle ? size / 2 : size * multiplier

        return self.resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(background)
            )
            .modifier(
                ZagNativeAppIconChrome(
                    cornerRadius: radius,
                    iconSize: size,
                    lineWidth: lineWidth,
                    isCircle: isCircle
                )
            )
    }
}

/// Native-feeling icon edge shared by every Image.appIconStyle call site.
///
/// Three distinct, low-opacity passes reproduce the App Store's optical depth:
/// an adaptive perimeter hairline, a bright *centred* top rim, and a shallow
/// bottom inset with a thin reflected lip. No blur, animation, or extra fetch.
/// Circular repository badges retain their existing plain border treatment.
private struct ZagNativeAppIconChrome: ViewModifier {
    let cornerRadius: CGFloat
    let iconSize: CGFloat
    let lineWidth: CGFloat
    let isCircle: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        content
            .clipShape(shape)
            .overlay {
                // An outline that's visible on black icons, without adding a
                // distracting grey box around brighter artwork.
                shape.strokeBorder(
                    Color.primary.opacity(isCircle ? 0.15 : (isDark ? 0.19 : 0.11)),
                    lineWidth: isCircle ? lineWidth : min(lineWidth, 0.75)
                )
            }
            .overlay {
                if !isCircle {
                    // A directional specular highlight, brightest at the
                    // *middle* of the upper rim, fading before the corners.
                    shape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(isDark ? 0.13 : 0.19), location: 0.28),
                                .init(color: .white.opacity(isDark ? 0.62 : 0.72), location: 0.50),
                                .init(color: .white.opacity(isDark ? 0.13 : 0.19), location: 0.72),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.05
                    )
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white.opacity(0.65), location: 0.10),
                                .init(color: .clear, location: 0.23),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                if !isCircle {
                    // Restrict the inset shadow to the last few percent of the
                    // artwork. Unlike a drop shadow, this stays INSIDE the icon.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.90),
                            .init(color: .black.opacity(isDark ? 0.10 : 0.07), location: 0.965),
                            .init(color: .black.opacity(isDark ? 0.21 : 0.13), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .mask(shape.inset(by: max(0.5, iconSize * 0.008)))
                }
            }
            .overlay {
                if !isCircle {
                    // A narrow reflected bottom lip produces the shallow
                    // inset/glass-edge finish visible in Apple's storefront.
                    shape.strokeBorder(
                        Color.white.opacity(isDark ? 0.17 : 0.29),
                        lineWidth: 0.65
                    )
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.82),
                                .init(color: .white.opacity(0.65), location: 0.95),
                                .init(color: .white, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .clipShape(shape)
    }
}

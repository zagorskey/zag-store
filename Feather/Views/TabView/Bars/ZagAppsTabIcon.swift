//
//  ZagAppsTabIcon.swift
//  Zag Store
//
//  A compact, purpose-drawn Apps tab symbol with a functional update dot.
//  The indicator is part of the icon itself, not a screen-positioned overlay.
//

import SwiftUI
import UIKit

/// A two-colour tab item image:
/// - the rounded-square outline follows the selected theme / native inactive colour;
/// - the red app-update indicator yields to the animated self-update spectrum.
///
/// Rendering as one high-resolution *original* image is intentional. The native
/// iOS tab bar otherwise template-tints the red dot alongside the outline.
struct ZagAppsTabIcon: View {
    let hasUpdates: Bool
    let hasStoreUpdate: Bool
    let isSelected: Bool
    let tintHex: String

    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Native tab bars snapshot the Label image and discard SwiftUI overlays.
    // Draw both the outline and update badge into the same UIImage.
    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 10.0,
            paused: !hasStoreUpdate || reduceMotion
        )) { timeline in
            Image(
                uiImage: Self.render(
                    hasUpdates: hasUpdates || hasStoreUpdate,
                    drawRedBadge: hasUpdates && !hasStoreUpdate,
                    drawSpectrumBadge: hasStoreUpdate,
                    spectrumPhase: reduceMotion ? 0 :
                        timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 5) / 5,
                    outlineColor: outlineColor
                )
            )
            .renderingMode(.original)
            .interpolation(.high)
            .accessibilityHidden(true)
        }
        .accessibilityHidden(true)
    }

    private var outlineColor: UIColor {
        if isSelected {
            return UIColor(ZagWideGamutTint.color(hex: tintHex))
        }
        // Match the other unselected dock icons: full-contrast white in dark
        // appearance and black in light appearance (never secondary gray).
        let traits = UITraitCollection(
            userInterfaceStyle: colorScheme == .dark ? .dark : .light
        )
        return UIColor.label.resolvedColor(with: traits)
    }

    private static func render(
        hasUpdates: Bool,
        drawRedBadge: Bool,
        drawSpectrumBadge: Bool,
        spectrumPhase: Double,
        outlineColor: UIColor
    ) -> UIImage {
        let canvas = CGSize(width: 30, height: 30)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        // Retina native tab assets: preserve the 2.65pt stroke and the
        // continuous corners rather than scaling a low-resolution bitmap.
        format.scale = UIScreen.main.scale

        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)

            // Match the 30pt Z icon's optical footprint: the square's stroke
            // reaches nearly the same top, bottom and side extents.
            // Reserve the upper-right corner for the update indicator.
            let frame = CGRect(x: 3.8, y: 4.4, width: 22.4, height: 22.4)
            let outline = UIBezierPath(
                roundedRect: frame,
                cornerRadius: 5.8
            )
            context.setLineWidth(2.85)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(outlineColor.cgColor)
            context.addPath(outline.cgPath)
            context.strokePath()

            guard hasUpdates else { return }

            // Precisely register the badge against the square's top-right
            // corner. Cut a transparent breathing gap in the stroke so the
            // badge reads as a single integrated mark, never a glued-on dot.
            let centre = CGPoint(x: 25.2, y: 4.8)
            let gapRadius: CGFloat = 5.65
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(
                x: centre.x - gapRadius,
                y: centre.y - gapRadius,
                width: gapRadius * 2,
                height: gapRadius * 2
            ))
            context.setBlendMode(.normal)

            if drawSpectrumBadge {
                let radius: CGFloat = 4.55
                let rect = CGRect(
                    x: centre.x - radius,
                    y: centre.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.saveGState()
                context.addEllipse(in: rect)
                context.clip()

                // Paint the spectrum into the native tab image itself.
                let palette: [UIColor] = [
                    UIColor(displayP3Red: 0.00, green: 1.00, blue: 1.00, alpha: 1),
                    UIColor(displayP3Red: 0.18, green: 0.62, blue: 1.00, alpha: 1),
                    UIColor(displayP3Red: 0.65, green: 0.38, blue: 1.00, alpha: 1),
                    UIColor(displayP3Red: 1.00, green: 0.30, blue: 0.96, alpha: 1)
                ]
                let angle = CGFloat(spectrumPhase) * .pi * 2
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                let reach: CGFloat = 4.8
                let start = CGPoint(
                    x: centre.x - direction.x * reach,
                    y: centre.y - direction.y * reach
                )
                let end = CGPoint(
                    x: centre.x + direction.x * reach,
                    y: centre.y + direction.y * reach
                )
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
                    colors: palette.map(\.cgColor) as CFArray,
                    locations: [0, 0.33, 0.67, 1]
                ) {
                    context.drawLinearGradient(
                        gradient, start: start, end: end,
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                    )
                }
                context.restoreGState()
                return
            }

            guard drawRedBadge else { return }

            let badgeRadius: CGFloat = 4.05
            context.setFillColor(
                UIColor(
                    displayP3Red: 1.0,
                    green: 0.12,
                    blue: 0.16,
                    alpha: 1.0
                ).cgColor
            )
            context.fillEllipse(in: CGRect(
                x: centre.x - badgeRadius,
                y: centre.y - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            ))
        }.withRenderingMode(.alwaysOriginal)
    }
}


/// Shared spectrum for the self-update progress bar, account indicator and
/// Apps dock indicator. Keep all three in sync when updating Zag Store colours.
enum ZagSelfUpdateSpectrum {
    static let colors: [Color] = [
        Color(red: 0.00, green: 0.86, blue: 1.00),
        Color(red: 0.05, green: 0.37, blue: 1.00),
        Color(red: 0.42, green: 0.18, blue: 1.00),
        Color(red: 0.95, green: 0.16, blue: 0.89),
        Color(red: 0.00, green: 0.86, blue: 1.00)
    ]
}


/// A single lightweight animated gradient for all self-update notifications.
/// Only the 8pt badge animates; the Apps glyph itself stays rasterized once.
struct ZagSelfUpdateSpectrumDot: View {
    var diameter: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { timeline in
            Circle()
                .fill(
                    AngularGradient(
                        colors: ZagSelfUpdateSpectrum.colors,
                        center: .center
                    )
                )
                .rotationEffect(.degrees(
                    reduceMotion ? 0 :
                        timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 5) * 72
                ))
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Zag Store update available")
    }
}

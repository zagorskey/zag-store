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
/// - the vivid P3-red indicator appears only while an update is available.
///
/// Rendering as one high-resolution *original* image is intentional. The native
/// iOS tab bar otherwise template-tints the red dot alongside the outline.
struct ZagAppsTabIcon: View {
    let hasUpdates: Bool
    let isSelected: Bool
    let tintHex: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(
            uiImage: Self.render(
                hasUpdates: hasUpdates,
                outlineColor: outlineColor
            )
        )
        .renderingMode(.original)
        .interpolation(.high)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.22), value: hasUpdates)
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

            // Deliberately smaller than the native icon slot to provide
            // balanced optical margins above/below and on both sides.
            let frame = CGRect(x: 5.0, y: 6.0, width: 20.0, height: 20.0)
            let outline = UIBezierPath(
                roundedRect: frame,
                cornerRadius: 5.2
            )
            context.setLineWidth(2.65)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(outlineColor.cgColor)
            context.addPath(outline.cgPath)
            context.strokePath()

            guard hasUpdates else { return }

            // Precisely register the badge against the square's top-right
            // corner. Cut a transparent breathing gap in the stroke so the
            // badge reads as a single integrated mark, never a glued-on dot.
            let centre = CGPoint(x: 24.0, y: 6.8)
            let gapRadius: CGFloat = 5.25
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(
                x: centre.x - gapRadius,
                y: centre.y - gapRadius,
                width: gapRadius * 2,
                height: gapRadius * 2
            ))
            context.setBlendMode(.normal)

            let badgeRadius: CGFloat = 4.15
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

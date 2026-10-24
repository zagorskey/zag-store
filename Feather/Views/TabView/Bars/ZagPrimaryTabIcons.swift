//
//  ZagPrimaryTabIcons.swift
//  Zag Store
//
//  Original, optically matched 30pt vector tab symbols.
//  UIKit renders at device scale; the system handles active/inactive tint.
//

import SwiftUI
import UIKit

enum ZagPrimaryTabIcons {
    enum Symbol {
        case discover
        case games
        case activity
    }

    static func label(for symbol: Symbol) -> some View {
        Image(uiImage: image(for: symbol))
            .renderingMode(.template)
            .accessibilityHidden(true)
    }

    private static let discoverImage = draw(.discover)
    private static let gamesImage = draw(.games)
    private static let activityImage = draw(.activity)

    private static func image(for symbol: Symbol) -> UIImage {
        switch symbol {
        case .discover: return discoverImage
        case .games: return gamesImage
        case .activity: return activityImage
        }
    }

    private static func draw(_ symbol: Symbol) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 30, height: 30),
            format: format
        )
        return renderer.image { result in
            let context = result.cgContext
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setStrokeColor(UIColor.black.cgColor)
            context.setFillColor(UIColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            switch symbol {
            case .discover:
                // A minimal navigation dial, not a filled Safari glyph.
                // Outer circle and tapered compass needle use a shared centre.
                context.setLineWidth(2.45)
                context.strokeEllipse(in: CGRect(x: 3.5, y: 3.5, width: 23, height: 23))

                let north = CGPoint(x: 20.9, y: 9.1)
                let east = CGPoint(x: 17.2, y: 17.5)
                let south = CGPoint(x: 9.1, y: 20.9)
                let west = CGPoint(x: 12.8, y: 12.5)
                let needle = UIBezierPath()
                needle.move(to: north)
                needle.addLine(to: east)
                needle.addLine(to: south)
                needle.addLine(to: west)
                needle.close()
                context.addPath(needle.cgPath)
                context.fillPath()

                // A precise negative-space centre makes the pointer readable
                // even when the dock scales the symbol down.
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 13.6, y: 13.6, width: 2.8, height: 2.8))
                context.setBlendMode(.normal)

            case .games:
                // DualSense-inspired front silhouette, drawn to the same
                // optical height as the 22.4pt Apps square. Clean continuous
                // shoulder curves and pronounced grips, never an SF glyph.
                let shell = UIBezierPath()
                shell.move(to: CGPoint(x: 9.4, y: 6.4))
                shell.addCurve(
                    to: CGPoint(x: 15.0, y: 4.6),
                    controlPoint1: CGPoint(x: 11.1, y: 4.9),
                    controlPoint2: CGPoint(x: 12.7, y: 4.6)
                )
                shell.addCurve(
                    to: CGPoint(x: 20.6, y: 6.4),
                    controlPoint1: CGPoint(x: 17.3, y: 4.6),
                    controlPoint2: CGPoint(x: 18.9, y: 4.9)
                )
                shell.addCurve(
                    to: CGPoint(x: 25.9, y: 13.1),
                    controlPoint1: CGPoint(x: 23.6, y: 6.4),
                    controlPoint2: CGPoint(x: 25.1, y: 10.0)
                )
                shell.addLine(to: CGPoint(x: 27.0, y: 20.6))
                shell.addCurve(
                    to: CGPoint(x: 22.8, y: 25.4),
                    controlPoint1: CGPoint(x: 27.6, y: 24.2),
                    controlPoint2: CGPoint(x: 25.5, y: 26.4)
                )
                shell.addCurve(
                    to: CGPoint(x: 18.8, y: 21.1),
                    controlPoint1: CGPoint(x: 21.8, y: 25.0),
                    controlPoint2: CGPoint(x: 20.3, y: 22.9)
                )
                shell.addCurve(
                    to: CGPoint(x: 11.2, y: 21.1),
                    controlPoint1: CGPoint(x: 16.5, y: 20.6),
                    controlPoint2: CGPoint(x: 13.5, y: 20.6)
                )
                shell.addCurve(
                    to: CGPoint(x: 7.2, y: 25.4),
                    controlPoint1: CGPoint(x: 9.7, y: 22.9),
                    controlPoint2: CGPoint(x: 8.2, y: 25.0)
                )
                shell.addCurve(
                    to: CGPoint(x: 3.0, y: 20.6),
                    controlPoint1: CGPoint(x: 4.5, y: 26.4),
                    controlPoint2: CGPoint(x: 2.4, y: 24.2)
                )
                shell.addLine(to: CGPoint(x: 4.1, y: 13.1))
                shell.addCurve(
                    to: CGPoint(x: 9.4, y: 6.4),
                    controlPoint1: CGPoint(x: 4.9, y: 10.0),
                    controlPoint2: CGPoint(x: 6.4, y: 6.4)
                )
                shell.close()
                context.setLineWidth(2.25)
                context.addPath(shell.cgPath)
                context.strokePath()

                // Distinctive inset DualSense touchpad. Thin enough not to
                // compete with the primary outline at actual tab-bar size.
                let touchpad = UIBezierPath(
                    roundedRect: CGRect(x: 11.8, y: 8.3, width: 6.4, height: 3.5),
                    cornerRadius: 1.35
                )
                context.setLineWidth(1.35)
                context.addPath(touchpad.cgPath)
                context.strokePath()

                // Balanced D-pad and four circular action buttons.
                context.setLineWidth(2.1)
                context.move(to: CGPoint(x: 9.6, y: 13.8))
                context.addLine(to: CGPoint(x: 9.6, y: 18.2))
                context.move(to: CGPoint(x: 7.4, y: 16.0))
                context.addLine(to: CGPoint(x: 11.8, y: 16.0))
                context.strokePath()

                let buttonRadius: CGFloat = 1.05
                for point in [
                    CGPoint(x: 20.4, y: 13.8),
                    CGPoint(x: 22.9, y: 16.3),
                    CGPoint(x: 20.4, y: 18.8),
                    CGPoint(x: 17.9, y: 16.3)
                ] {
                    context.fillEllipse(in: CGRect(
                        x: point.x - buttonRadius,
                        y: point.y - buttonRadius,
                        width: buttonRadius * 2,
                        height: buttonRadius * 2
                    ))
                }

            case .activity:
                // A clear live-activity signal, not a generic history clock:
                // precisely centred circular carrier and one continuous
                // pulse trace. Same near-25pt optical extent as the Apps icon.
                context.setLineWidth(2.45)
                context.strokeEllipse(in: CGRect(
                    x: 3.9, y: 3.9, width: 22.2, height: 22.2
                ))

                let pulse = UIBezierPath()
                pulse.move(to: CGPoint(x: 7.9, y: 15.5))
                pulse.addLine(to: CGPoint(x: 11.0, y: 15.5))
                pulse.addLine(to: CGPoint(x: 13.2, y: 11.1))
                pulse.addLine(to: CGPoint(x: 16.0, y: 19.0))
                pulse.addLine(to: CGPoint(x: 18.2, y: 14.0))
                pulse.addLine(to: CGPoint(x: 22.1, y: 14.0))
                context.setLineWidth(2.35)
                context.addPath(pulse.cgPath)
                context.strokePath()
            }
        }.withRenderingMode(.alwaysTemplate)
    }
}

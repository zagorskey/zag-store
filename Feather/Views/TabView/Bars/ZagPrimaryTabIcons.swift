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
                // Original continuous-outline controller. The shape remains
                // airy instead of becoming a heavy filled SF gamepad.
                let shell = UIBezierPath()
                shell.move(to: CGPoint(x: 9.1, y: 10.2))
                shell.addCurve(to: CGPoint(x: 20.9, y: 10.2),
                               controlPoint1: CGPoint(x: 12.1, y: 9.1),
                               controlPoint2: CGPoint(x: 17.9, y: 9.1))
                shell.addCurve(to: CGPoint(x: 25.4, y: 16.4),
                               controlPoint1: CGPoint(x: 24.1, y: 10.8),
                               controlPoint2: CGPoint(x: 24.7, y: 13.1))
                shell.addLine(to: CGPoint(x: 26.6, y: 20.2))
                shell.addCurve(to: CGPoint(x: 22.0, y: 23.2),
                               controlPoint1: CGPoint(x: 27.5, y: 23.6),
                               controlPoint2: CGPoint(x: 24.7, y: 25.0))
                shell.addLine(to: CGPoint(x: 18.1, y: 20.1))
                shell.addCurve(to: CGPoint(x: 11.9, y: 20.1),
                               controlPoint1: CGPoint(x: 16.5, y: 19.3),
                               controlPoint2: CGPoint(x: 13.5, y: 19.3))
                shell.addLine(to: CGPoint(x: 8.0, y: 23.2))
                shell.addCurve(to: CGPoint(x: 3.4, y: 20.2),
                               controlPoint1: CGPoint(x: 5.3, y: 25.0),
                               controlPoint2: CGPoint(x: 2.5, y: 23.6))
                shell.addLine(to: CGPoint(x: 4.6, y: 16.4))
                shell.addCurve(to: CGPoint(x: 9.1, y: 10.2),
                               controlPoint1: CGPoint(x: 5.3, y: 13.1),
                               controlPoint2: CGPoint(x: 5.9, y: 10.8))
                shell.close()
                context.setLineWidth(2.4)
                context.addPath(shell.cgPath)
                context.strokePath()

                // Rounded directional pad.
                context.setLineWidth(2.35)
                context.move(to: CGPoint(x: 10.4, y: 13.3))
                context.addLine(to: CGPoint(x: 10.4, y: 18.0))
                context.move(to: CGPoint(x: 8.05, y: 15.65))
                context.addLine(to: CGPoint(x: 12.75, y: 15.65))
                context.strokePath()
                context.fillEllipse(in: CGRect(x: 19.3, y: 13.1, width: 2.7, height: 2.7))
                context.fillEllipse(in: CGRect(x: 22.0, y: 16.1, width: 2.7, height: 2.7))

            case .activity:
                // Clock/history motif: clean 270-degree arc, short hands,
                // and a small return arrow integrated into the circle.
                let circle = UIBezierPath(
                    arcCenter: CGPoint(x: 15, y: 15),
                    radius: 11.4,
                    startAngle: -.pi / 2,
                    endAngle: .pi,
                    clockwise: true
                )
                context.setLineWidth(2.5)
                context.addPath(circle.cgPath)
                context.strokePath()

                // Return arrow meets the open top-left of the history arc.
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: 3.6, y: 8.1))
                arrow.addLine(to: CGPoint(x: 3.6, y: 15.0))
                arrow.addLine(to: CGPoint(x: 10.5, y: 15.0))
                context.addPath(arrow.cgPath)
                context.strokePath()

                // Clock hands, optically centred and rounded.
                context.move(to: CGPoint(x: 15, y: 8.8))
                context.addLine(to: CGPoint(x: 15, y: 15))
                context.addLine(to: CGPoint(x: 19.3, y: 17.5))
                context.strokePath()
            }
        }.withRenderingMode(.alwaysTemplate)
    }
}

import SwiftUI
import UIKit

/// Monochrome adaptation of the rounded, continuous Zag Store Z mark.
/// Rendered as a template image so UITabBarAppearance supplies the active
/// theme tint and the system supplies the inactive tint.
enum ZagSourcesTabIcon {
    static let image: UIImage = {
        let size = CGSize(width: 30, height: 30)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let ctx = context.cgContext
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(5.8)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let path = UIBezierPath()
            // Horizontal top, descending diagonal, horizontal base.
            // The rounded terminals mirror the original neon Z silhouette.
            path.move(to: CGPoint(x: 5.1, y: 6.6))
            path.addLine(to: CGPoint(x: 24.7, y: 6.6))
            path.addLine(to: CGPoint(x: 5.1, y: 23.4))
            path.addLine(to: CGPoint(x: 24.7, y: 23.4))
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

    static var label: some View {
        Image(uiImage: image)
            .renderingMode(.template)
    }
}

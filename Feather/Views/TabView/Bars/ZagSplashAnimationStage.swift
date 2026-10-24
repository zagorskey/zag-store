//
//  ZagSplashAnimationStage.swift
//  Zag Store — premium cold-launch motion
//
//  The existing ZagSplashFull image supplies the genuine 3D Z (all colour,
//  bevel and internal reflections). Only the reveal mask is a vector path.
//

import SwiftUI
import UIKit
import QuartzCore

struct ZagSplashAnimationStage: UIViewRepresentable {
    let reduceMotion: Bool

    func makeUIView(context: Context) -> ZagSplashStageView {
        ZagSplashStageView(reduceMotion: reduceMotion)
    }

    func updateUIView(_ uiView: ZagSplashStageView, context: Context) { }
}

/// Cache the cropped real 3D logo once, instead of decoding an image on every
/// frame. The source has a gradient baked behind the mark, so recover a soft
/// alpha based on brightness AND proximity to the three actual Z strokes.
/// No AI redrawing, traced flat logo, or visual substitution is involved.
@MainActor
private enum ZagSplashMarkAsset {
    static let originalSize = CGSize(width: 863, height: 1822)
    static let crop = CGRect(x: 133, y: 572, width: 597, height: 690)
    static let image: CGImage? = makeImage()

    private static func makeImage() -> CGImage? {
        guard let source = UIImage(named: "ZagSplashFull")?.cgImage else {
            return nil
        }
        let rect = CGRect(
            x: CGFloat(source.width) * crop.minX / originalSize.width,
            y: CGFloat(source.height) * crop.minY / originalSize.height,
            width: CGFloat(source.width) * crop.width / originalSize.width,
            height: CGFloat(source.height) * crop.height / originalSize.height
        ).integral
        guard let cropped = source.cropping(to: rect) else { return nil }

        let width = cropped.width
        let height = cropped.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: height * rowBytes)
        let space = CGColorSpaceCreateDeviceRGB()
        let flags = CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue

        let success = pixels.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: space,
                bitmapInfo: flags
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                cropped,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard success else { return nil }

        func segmentDistance(
            _ x: CGFloat, _ y: CGFloat,
            _ x0: CGFloat, _ y0: CGFloat,
            _ x1: CGFloat, _ y1: CGFloat
        ) -> CGFloat {
            let dx = x1 - x0
            let dy = y1 - y0
            let t = min(1, max(0, ((x - x0) * dx + (y - y0) * dy) / (dx * dx + dy * dy)))
            return hypot(x - x0 - t * dx, y - y0 - t * dy)
        }

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let pixel = index / 4
            let x = crop.minX + CGFloat(pixel % width) * crop.width / CGFloat(width)
            let y = crop.minY + CGFloat(pixel / width) * crop.height / CGFloat(height)
            let distance = min(
                segmentDistance(x, y, 249, 711, 615, 711),
                min(
                    segmentDistance(x, y, 615, 711, 249, 1084),
                    segmentDistance(x, y, 249, 1084, 615, 1084)
                )
            )
            let outer = min(1, max(0, (130 - distance) / 52))
            let geometry = outer * outer * (3 - 2 * outer)

            let value = CGFloat(
                max(pixels[index], max(pixels[index + 1], pixels[index + 2]))
            ) / 255
            let t = min(1, max(0, (value - 0.14) / 0.34))
            let luminance = t * t * (3 - 2 * t)
            let alpha = geometry * luminance

            // This is a premultiplied RGBA buffer.
            pixels[index] = UInt8(CGFloat(pixels[index]) * alpha)
            pixels[index + 1] = UInt8(CGFloat(pixels[index + 1]) * alpha)
            pixels[index + 2] = UInt8(CGFloat(pixels[index + 2]) * alpha)
            pixels[index + 3] = UInt8(255 * alpha)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: flags),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Layer-backed motion, designed to run on the Core Animation render server.
/// There is no 60fps SwiftUI bitmap redrawing, blur loop or launch-time network.
final class ZagSplashStageView: UIView {
    private let backdrop = UIImageView(image: UIImage(named: "ZagSplashBackdrop"))
    private let reduceMotion: Bool
    private var started = false

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 4 / 255, green: 5 / 255, blue: 16 / 255, alpha: 1)
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        guard !started, bounds.width > 10, bounds.height > 10 else { return }
        started = true
        buildLayers()
    }

    private func buildLayers() {
        guard let mark = ZagSplashMarkAsset.image else { return }
        let source = ZagSplashMarkAsset.originalSize
        let crop = ZagSplashMarkAsset.crop
        let scale = max(bounds.width / source.width, bounds.height / source.height)
        let originX = (bounds.width - source.width * scale) / 2
        let originY = (bounds.height - source.height * scale) / 2

        let root = CALayer()
        root.frame = CGRect(
            x: originX + crop.minX * scale,
            y: originY + crop.minY * scale,
            width: crop.width * scale,
            height: crop.height * scale
        )
        root.masksToBounds = false
        layer.addSublayer(root)
        let rect = root.bounds

        func bloom(_ color: UIColor, horizontalOffset: CGFloat) -> CAGradientLayer {
            let volume = CAGradientLayer()
            volume.type = .radial
            volume.colors = [
                color.withAlphaComponent(0.38).cgColor,
                color.withAlphaComponent(0.10).cgColor,
                UIColor.clear.cgColor
            ]
            volume.locations = [0, 0.46, 1]
            volume.startPoint = CGPoint(x: 0.5, y: 0.5)
            volume.endPoint = CGPoint(x: 1, y: 1)
            volume.frame = rect.insetBy(
                dx: -rect.width * 0.42,
                dy: -rect.height * 0.30
            )
            volume.position.x += horizontalOffset * rect.width
            volume.opacity = reduceMotion ? 0.34 : 0
            root.addSublayer(volume)
            return volume
        }

        let cyan = bloom(
            UIColor(displayP3Red: 0, green: 0.74, blue: 1, alpha: 1),
            horizontalOffset: -0.20
        )
        let magenta = bloom(
            UIColor(displayP3Red: 0.85, green: 0.19, blue: 1, alpha: 1),
            horizontalOffset: 0.23
        )

        let image = CALayer()
        image.frame = rect
        image.contents = mark
        image.contentsGravity = .resize
        image.contentsScale = UIScreen.main.scale
        image.minificationFilter = .trilinear
        image.magnificationFilter = .linear
        image.shadowColor = UIColor(
            displayP3Red: 0.25, green: 0.57, blue: 1, alpha: 1
        ).cgColor
        image.shadowRadius = 18 * scale
        image.shadowOpacity = reduceMotion ? 0.3 : 0.48
        image.shadowOffset = .zero
        root.addSublayer(image)

        var path = UIBezierPath()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - crop.minX) * scale, y: (y - crop.minY) * scale)
        }
        path.move(to: point(249, 711))
        path.addLine(to: point(615, 711))
        path.addLine(to: point(249, 1084))
        path.addLine(to: point(615, 1084))

        let mask = CAShapeLayer()
        mask.frame = rect
        mask.path = path.cgPath
        mask.fillColor = nil
        mask.strokeColor = UIColor.white.cgColor
        mask.lineWidth = 153 * scale
        mask.lineCap = .round
        mask.lineJoin = .round
        mask.strokeEnd = reduceMotion ? 1 : 0
        image.mask = mask

        if reduceMotion { return }
        let time = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Three controlled strokes expose the original translucent 3D Z.
        mask.strokeEnd = 1
        let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
        draw.values = [0, 0.29, 0.72, 1]
        draw.keyTimes = [0, 0.27, 0.73, 1]
        draw.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        draw.beginTime = time + 0.20
        draw.duration = 1.38
        draw.fillMode = .both
        draw.isRemovedOnCompletion = false
        mask.add(draw, forKey: "zag.3D.draw")

        // A very narrow, glowing lead point gives the draw physical energy.
        // It never covers the mark in a flat white stroke.
        let head = CAShapeLayer()
        head.frame = rect
        head.path = path.cgPath
        head.fillColor = nil
        head.strokeColor = UIColor(
            displayP3Red: 0.78, green: 0.95, blue: 1, alpha: 0.85
        ).cgColor
        head.lineWidth = 4.4 * scale
        head.lineCap = .round
        head.lineJoin = .round
        head.shadowColor = UIColor(
            displayP3Red: 0, green: 0.90, blue: 1, alpha: 1
        ).cgColor
        head.shadowOpacity = 0.88
        head.shadowRadius = 12 * scale
        head.shadowOffset = .zero
        head.opacity = 0
        root.addSublayer(head)

        let leading = CAKeyframeAnimation(keyPath: "strokeStart")
        leading.values = [0, 0.24, 0.69, 0.97]
        leading.keyTimes = [0, 0.27, 0.73, 1]
        leading.beginTime = time + 0.20
        leading.duration = 1.38
        leading.fillMode = .both
        leading.isRemovedOnCompletion = false
        head.add(leading, forKey: "zag.head.leading")

        let trailing = CAKeyframeAnimation(keyPath: "strokeEnd")
        trailing.values = [0.035, 0.30, 0.75, 1]
        trailing.keyTimes = [0, 0.27, 0.73, 1]
        trailing.beginTime = time + 0.20
        trailing.duration = 1.38
        trailing.fillMode = .both
        trailing.isRemovedOnCompletion = false
        head.add(trailing, forKey: "zag.head.trailing")

        let headFade = CAKeyframeAnimation(keyPath: "opacity")
        headFade.values = [0, 0.75, 0.8, 0]
        headFade.keyTimes = [0, 0.12, 0.77, 1]
        headFade.beginTime = time + 0.19
        headFade.duration = 1.45
        headFade.fillMode = .both
        headFade.isRemovedOnCompletion = false
        head.add(headFade, forKey: "zag.head.fade")

        // A studio specular highlight follows the ORIGINAL alpha silhouette
        // only, with iridescent cyan rather than an all-white rectangle.
        let specular = CAGradientLayer()
        specular.frame = rect
        specular.colors = [
            UIColor.clear.cgColor,
            UIColor.white.withAlphaComponent(0.02).cgColor,
            UIColor.white.withAlphaComponent(0.50).cgColor,
            UIColor(displayP3Red: 0.55, green: 0.91, blue: 1, alpha: 0.12).cgColor,
            UIColor.clear.cgColor
        ]
        specular.locations = [0, 0.41, 0.50, 0.60, 1]
        specular.startPoint = CGPoint(x: -1, y: 0)
        specular.endPoint = CGPoint(x: 0, y: 0)
        specular.opacity = 0
        let specularMask = CALayer()
        specularMask.frame = rect
        specularMask.contents = mark
        specularMask.contentsGravity = .resize
        specular.mask = specularMask
        root.addSublayer(specular)

        let startMotion = CABasicAnimation(keyPath: "startPoint")
        startMotion.fromValue = NSValue(cgPoint: CGPoint(x: -1, y: 0))
        startMotion.toValue = NSValue(cgPoint: CGPoint(x: 1, y: 1))
        startMotion.beginTime = time + 1.24
        startMotion.duration = 0.82
        startMotion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        startMotion.fillMode = .both
        startMotion.isRemovedOnCompletion = false
        specular.add(startMotion, forKey: "zag.specular.start")

        let endMotion = CABasicAnimation(keyPath: "endPoint")
        endMotion.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: 0))
        endMotion.toValue = NSValue(cgPoint: CGPoint(x: 2, y: 1))
        endMotion.beginTime = time + 1.24
        endMotion.duration = 0.82
        endMotion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        endMotion.fillMode = .both
        endMotion.isRemovedOnCompletion = false
        specular.add(endMotion, forKey: "zag.specular.end")

        let sheen = CAKeyframeAnimation(keyPath: "opacity")
        sheen.values = [0, 0.64, 0.64, 0]
        sheen.keyTimes = [0, 0.22, 0.75, 1]
        sheen.beginTime = time + 1.21
        sheen.duration = 0.89
        sheen.fillMode = .both
        sheen.isRemovedOnCompletion = false
        specular.add(sheen, forKey: "zag.specular.intensity")

        func animateBloom(_ volume: CALayer, delay: CFTimeInterval) {
            volume.opacity = 0.36
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0, 0.36, 0.83, 0.36]
            pulse.keyTimes = [0, 0.30, 0.72, 1]
            pulse.beginTime = time + delay
            pulse.duration = 2.18
            pulse.fillMode = .both
            pulse.isRemovedOnCompletion = false
            volume.add(pulse, forKey: "zag.bloom")
        }
        animateBloom(cyan, delay: 0.06)
        animateBloom(magenta, delay: 0.12)

        // A nearly imperceptible focus lock—no bounce or cartoony spring.
        let focus = CAKeyframeAnimation(keyPath: "transform.scale")
        focus.values = [0.972, 0.993, 1.011, 1]
        focus.keyTimes = [0, 0.61, 0.83, 1]
        focus.beginTime = time + 0.16
        focus.duration = 2.22
        focus.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        focus.fillMode = .both
        focus.isRemovedOnCompletion = false
        root.add(focus, forKey: "zag.focus")

        CATransaction.commit()
    }
}

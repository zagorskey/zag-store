//
// ZagSplashAnimationStage.swift
// Zag Store: original-artwork, layer-driven cold-start motion.
//
// The translucent 3D Z is the exact user-supplied artwork, isolated once into
// ZagSplashZIsolated.imageset. Geometry below drives REVEAL only; it never
// manufactures, re-colours or cuts the final logo. Everything runs in Core
// Animation (no display-link bitmap drawing during the splash).
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

final class ZagSplashStageView: UIView {
    private let backdrop = UIImageView(image: UIImage(named: "ZagSplashBackdrop"))
    private let reduceMotion: Bool
    private var assembled = false

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 4.0 / 255.0, green: 6.0 / 255.0, blue: 18.0 / 255.0, alpha: 1)
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        guard !assembled, bounds.width > 20, bounds.height > 20 else { return }
        assembled = true
        assembleScene()
    }

    private func assembleScene() {
        guard let artwork = UIImage(named: "ZagSplashZIsolated")?.cgImage else {
            // Never recreate a fake Z or show a malformed extracted image.
            return
        }

        let width = min(bounds.width * 0.635, 286)
        let height = width * CGFloat(artwork.height) / CGFloat(artwork.width)
        let logoRect = CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height * 0.425 - height / 2,
            width: width,
            height: height
        )
        let canvas = CGRect(origin: .zero, size: logoRect.size)
        let tick = CACurrentMediaTime() + 0.05
        let scale = width / 692.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let glow = CALayer()
        glow.frame = logoRect.insetBy(dx: -width * 0.31, dy: -height * 0.31)
        glow.opacity = reduceMotion ? 0.55 : 0.0
        layer.addSublayer(glow)

        func addBloom(color: UIColor, x: CGFloat, strength: CGFloat) -> CAGradientLayer {
            let bloom = CAGradientLayer()
            bloom.type = .radial
            bloom.frame = glow.bounds
            bloom.startPoint = CGPoint(x: x, y: 0.52)
            bloom.endPoint = CGPoint(x: x + 0.47, y: 1.0)
            bloom.colors = [
                color.withAlphaComponent(strength).cgColor,
                color.withAlphaComponent(strength * 0.26).cgColor,
                UIColor.clear.cgColor
            ]
            bloom.locations = [0, 0.48, 1]
            glow.addSublayer(bloom)
            return bloom
        }

        _ = addBloom(
            color: UIColor(displayP3Red: 0, green: 0.81, blue: 1, alpha: 1),
            x: 0.35, strength: 0.47
        )
        _ = addBloom(
            color: UIColor(displayP3Red: 0.83, green: 0.17, blue: 1, alpha: 1),
            x: 0.67, strength: 0.36
        )

        // Mirrored reflection: same bitmap, same reveal timeline and same
        // specular motion. The small lower window is softly masked out.
        let reflectionHeight = min(height * 0.24, 70)
        let reflectedWindow = CALayer()
        reflectedWindow.frame = CGRect(
            x: logoRect.minX,
            y: logoRect.maxY + 6,
            width: width,
            height: reflectionHeight
        )
        reflectedWindow.masksToBounds = true
        reflectedWindow.opacity = reduceMotion ? 0.48 : 0
        layer.addSublayer(reflectedWindow)

        let reflectedGroup = CALayer()
        reflectedGroup.frame = canvas
        reflectedGroup.transform = CATransform3DMakeScale(1, -1, 1)
        reflectedWindow.addSublayer(reflectedGroup)

        let reflectionFade = CAGradientLayer()
        reflectionFade.frame = reflectedWindow.bounds
        reflectionFade.colors = [
            UIColor.white.withAlphaComponent(0.26).cgColor,
            UIColor.white.withAlphaComponent(0.11).cgColor,
            UIColor.clear.cgColor
        ]
        reflectionFade.locations = [0, 0.39, 1]
        reflectionFade.startPoint = CGPoint(x: 0.5, y: 0)
        reflectionFade.endPoint = CGPoint(x: 0.5, y: 1)
        reflectedWindow.mask = reflectionFade

        let logoGroup = CALayer()
        logoGroup.frame = logoRect
        layer.addSublayer(logoGroup)

        // Every copy uses only the original untouched alpha PNG, ensuring
        // exact geometry at the end of the entrance.
        func mark(in group: CALayer, initialOpacity: Float) -> CALayer {
            let image = CALayer()
            image.frame = canvas
            image.contents = artwork
            image.contentsGravity = .resizeAspect
            image.contentsScale = UIScreen.main.scale
            image.minificationFilter = .trilinear
            image.magnificationFilter = .linear
            image.opacity = initialOpacity
            group.addSublayer(image)
            return image
        }

        func revealPath() -> CGPath {
            // Normalised to the exact source crop 692 × 711 (rather than the
            // old 863 × 1822 screenshot that inverted/clipped the logo).
            let path = UIBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            path.move(to: p(132, 116))
            path.addLine(to: p(580, 116))
            path.addLine(to: p(130, 601))
            path.addLine(to: p(580, 601))
            return path.cgPath
        }
        let centerline = revealPath()

        func setRevealMask(on image: CALayer) -> CAShapeLayer {
            let mask = CAShapeLayer()
            mask.frame = canvas
            mask.path = centerline
            mask.fillColor = nil
            mask.strokeColor = UIColor.white.cgColor
            // This is an envelope over the ALREADY transparent bitmap, not a
            // geometry cutter. Full artwork crossfades in before completion.
            mask.lineWidth = 240 * scale
            mask.lineCap = .round
            mask.lineJoin = .round
            mask.strokeEnd = reduceMotion ? 1 : 0
            image.mask = mask
            return mask
        }

        let reflectionDraw = mark(in: reflectedGroup, initialOpacity: 1)
        let reflectionMask = setRevealMask(on: reflectionDraw)
        let reflectionComplete = mark(in: reflectedGroup, initialOpacity: reduceMotion ? 1 : 0)

        let drawnZ = mark(in: logoGroup, initialOpacity: 1)
        let drawMask = setRevealMask(on: drawnZ)
        let completeZ = mark(in: logoGroup, initialOpacity: reduceMotion ? 1 : 0)
        completeZ.shadowColor = UIColor(
            displayP3Red: 0.18, green: 0.50, blue: 1, alpha: 1
        ).cgColor
        completeZ.shadowOpacity = 0.33
        completeZ.shadowRadius = 15
        completeZ.shadowOffset = .zero

        func addStudioReflection(to group: CALayer) -> CAGradientLayer {
            let sheen = CAGradientLayer()
            sheen.frame = CGRect(x: -width * 0.80, y: 0, width: width * 0.72, height: height)
            sheen.colors = [
                UIColor.clear.cgColor,
                UIColor.white.withAlphaComponent(0.03).cgColor,
                UIColor.white.withAlphaComponent(0.58).cgColor,
                UIColor(displayP3Red: 0.59, green: 0.94, blue: 1, alpha: 0.21).cgColor,
                UIColor.clear.cgColor
            ]
            sheen.locations = [0, 0.34, 0.51, 0.68, 1]
            sheen.startPoint = CGPoint(x: 0, y: 0)
            sheen.endPoint = CGPoint(x: 1, y: 1)
            sheen.opacity = reduceMotion ? 0 : 0.68

            // The travelling light is clipped to the REAL alpha of the mark.
            let clip = CALayer()
            clip.frame = canvas
            clip.contents = artwork
            clip.contentsGravity = .resizeAspect
            clip.contentsScale = UIScreen.main.scale
            let sleeve = CALayer()
            sleeve.frame = canvas
            sleeve.mask = clip
            group.addSublayer(sleeve)
            sleeve.addSublayer(sheen)
            return sheen
        }

        let specular = addStudioReflection(to: logoGroup)
        let mirrorSpecular = addStudioReflection(to: reflectedGroup)

        let motto = CATextLayer()
        motto.contentsScale = UIScreen.main.scale
        motto.alignmentMode = .center
        motto.truncationMode = .none
        motto.isWrapped = false
        let pointSize = min(19.5, max(15.8, bounds.width * 0.044))
        motto.string = NSAttributedString(
            string: "Sideloading and beyond.",
            attributes: [
                .font: UIFont.systemFont(ofSize: pointSize, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.98),
                .kern: 0.15
            ]
        )
        motto.frame = CGRect(
            x: 12,
            y: max(logoRect.maxY + reflectionHeight + 24, bounds.height * 0.674),
            width: bounds.width - 24,
            height: pointSize * 1.65
        )
        motto.opacity = reduceMotion ? 1 : 0
        layer.addSublayer(motto)

        let mottoWipe = CAShapeLayer()
        mottoWipe.frame = motto.bounds
        mottoWipe.path = UIBezierPath(rect: motto.bounds).cgPath
        mottoWipe.fillColor = UIColor.white.cgColor
        mottoWipe.anchorPoint = CGPoint(x: 0, y: 0.5)
        mottoWipe.position = CGPoint(x: 0, y: motto.bounds.midY)
        mottoWipe.bounds.size.width = reduceMotion ? motto.bounds.width : 0
        motto.mask = mottoWipe

        guard !reduceMotion else {
            CATransaction.commit()
            return
        }

        // Smooth, intentionally paced Z draw: three passages of equal visual
        // weight, rather than a single mechanical linear trim animation.
        func animateDraw(_ mask: CAShapeLayer) {
            mask.strokeEnd = 1
            let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
            draw.values = [0, 0.285, 0.735, 1]
            draw.keyTimes = [0, 0.285, 0.765, 1]
            draw.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeOut)
            ]
            draw.beginTime = tick + 0.15
            draw.duration = 1.50
            draw.fillMode = .both
            draw.isRemovedOnCompletion = false
            mask.add(draw, forKey: "zag.strokeReveal")
        }
        animateDraw(drawMask)
        animateDraw(reflectionMask)

        func animateFullArtwork(_ finished: CALayer, _ drawing: CALayer) {
            finished.opacity = 1
            drawing.opacity = 0
            let arrive = CABasicAnimation(keyPath: "opacity")
            arrive.fromValue = 0
            arrive.toValue = 1
            arrive.beginTime = tick + 1.46
            arrive.duration = 0.32
            arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arrive.fillMode = .both
            arrive.isRemovedOnCompletion = false
            finished.add(arrive, forKey: "zag.complete")

            let retire = CABasicAnimation(keyPath: "opacity")
            retire.fromValue = 1
            retire.toValue = 0
            retire.beginTime = tick + 1.46
            retire.duration = 0.32
            retire.fillMode = .both
            retire.isRemovedOnCompletion = false
            drawing.add(retire, forKey: "zag.retireMask")
        }
        animateFullArtwork(completeZ, drawnZ)
        animateFullArtwork(reflectionComplete, reflectionDraw)

        glow.opacity = 0.60
        let bloom = CAKeyframeAnimation(keyPath: "opacity")
        bloom.values = [0.04, 0.24, 0.72, 0.48, 0.60]
        bloom.keyTimes = [0, 0.18, 0.63, 0.83, 1]
        bloom.beginTime = tick + 0.18
        bloom.duration = 2.34
        bloom.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        bloom.fillMode = .both
        bloom.isRemovedOnCompletion = false
        glow.add(bloom, forKey: "zag.bloom")

        reflectedWindow.opacity = 0.57
        let reflectionFadeIn = CABasicAnimation(keyPath: "opacity")
        reflectionFadeIn.fromValue = 0
        reflectionFadeIn.toValue = 0.57
        reflectionFadeIn.beginTime = tick + 0.52
        reflectionFadeIn.duration = 1.18
        reflectionFadeIn.fillMode = .both
        reflectionFadeIn.isRemovedOnCompletion = false
        reflectionFadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        reflectedWindow.add(reflectionFadeIn, forKey: "zag.reflectionLive")

        // Both the logo and its actual mirror receive the travelling beam.
        func animateSheen(_ sheen: CALayer) {
            let travel = CABasicAnimation(keyPath: "position.x")
            travel.fromValue = -width * 0.44
            travel.toValue = width * 1.30
            travel.beginTime = tick + 1.19
            travel.duration = 0.98
            travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            travel.fillMode = .both
            travel.isRemovedOnCompletion = false
            sheen.position.x = width * 1.30
            sheen.add(travel, forKey: "zag.specularTravel")

            let amplitude = CAKeyframeAnimation(keyPath: "opacity")
            amplitude.values = [0, 0.76, 0.70, 0]
            amplitude.keyTimes = [0, 0.24, 0.72, 1]
            amplitude.beginTime = tick + 1.19
            amplitude.duration = 0.98
            amplitude.fillMode = .both
            amplitude.isRemovedOnCompletion = false
            sheen.opacity = 0
            sheen.add(amplitude, forKey: "zag.specularGlow")
        }
        animateSheen(specular)
        animateSheen(mirrorSpecular)

        motto.opacity = 1
        let textFade = CAKeyframeAnimation(keyPath: "opacity")
        textFade.values = [0, 0.30, 1]
        textFade.keyTimes = [0, 0.22, 1]
        textFade.beginTime = tick + 1.65
        textFade.duration = 0.62
        textFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        textFade.fillMode = .both
        textFade.isRemovedOnCompletion = false
        motto.add(textFade, forKey: "zag.mottoFade")

        mottoWipe.bounds.size.width = motto.bounds.width
        let revealText = CABasicAnimation(keyPath: "bounds.size.width")
        revealText.fromValue = 0
        revealText.toValue = motto.bounds.width
        revealText.beginTime = tick + 1.60
        revealText.duration = 0.78
        revealText.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        revealText.fillMode = .both
        revealText.isRemovedOnCompletion = false
        mottoWipe.add(revealText, forKey: "zag.mottoDraw")

        let focus = CAKeyframeAnimation(keyPath: "transform.scale")
        focus.values = [0.984, 0.989, 1.008, 1]
        focus.keyTimes = [0, 0.52, 0.80, 1]
        focus.beginTime = tick + 0.12
        focus.duration = 2.34
        focus.fillMode = .both
        focus.isRemovedOnCompletion = false
        focus.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        logoGroup.add(focus, forKey: "zag.focusSettle")

        CATransaction.commit()
    }
}
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
        // Match the launch storyboard: reduce the ambient wash so the
        // untouched cyan/blue/magenta 3D artwork remains the focal point.
        backdrop.alpha = 0.52
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

        let width = min(bounds.width * 0.68, 310)
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
        glow.opacity = reduceMotion ? 0.20 : 0.0
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

        let cyanBloom = addBloom(
            color: UIColor(displayP3Red: 0, green: 0.81, blue: 1, alpha: 1),
            x: 0.35, strength: 0.19
        )
        let magentaBloom = addBloom(
            color: UIColor(displayP3Red: 0.83, green: 0.17, blue: 1, alpha: 1),
            x: 0.67, strength: 0.15
        )

        // Mirrored reflection: same bitmap, same reveal timeline and same
        // specular motion. The small lower window is softly masked out.
        let reflectionHeight = min(height * 0.29, 91)
        let reflectedWindow = CALayer()
        reflectedWindow.frame = CGRect(
            x: logoRect.minX,
            y: logoRect.maxY + 4,
            width: width,
            height: reflectionHeight
        )
        reflectedWindow.masksToBounds = true
        reflectedWindow.opacity = reduceMotion ? 0.68 : 0
        layer.addSublayer(reflectedWindow)

        let reflectedGroup = CALayer()
        reflectedGroup.frame = canvas
        reflectedGroup.transform = CATransform3DMakeScale(1, -1, 1)
        reflectedWindow.addSublayer(reflectedGroup)

        let reflectionFade = CAGradientLayer()
        reflectionFade.frame = reflectedWindow.bounds
        reflectionFade.colors = [
            UIColor.white.withAlphaComponent(0.72).cgColor,
            UIColor.white.withAlphaComponent(0.30).cgColor,
            UIColor.clear.cgColor
        ]
        reflectionFade.locations = [0, 0.43, 1]
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

        // The animated energy travels along the very same centreline as the
        // artwork reveal. This avoids a disconnected white line or a second Z.
        // The transparent logo PNG is used as the clip for ALL light passes.
        func artworkAlphaMask() -> CALayer {
            let alpha = CALayer()
            alpha.frame = canvas
            alpha.contents = artwork
            alpha.contentsGravity = .resizeAspect
            alpha.contentsScale = UIScreen.main.scale
            return alpha
        }

        func setRevealMask(on image: CALayer) -> CAShapeLayer {
            let mask = CAShapeLayer()
            mask.frame = canvas
            mask.path = centerline
            mask.fillColor = nil
            mask.strokeColor = UIColor.white.cgColor
            // This is an envelope over the ALREADY transparent bitmap, not a
            // geometry cutter. Full artwork crossfades in before completion.
            mask.lineWidth = 265 * scale
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
        completeZ.shadowOpacity = 0.12
        completeZ.shadowRadius = 9
        completeZ.shadowOffset = .zero

        func addStudioReflection(to group: CALayer) -> CAGradientLayer {
            let sheen = CAGradientLayer()
            sheen.frame = CGRect(x: -width * 0.80, y: 0, width: width * 0.72, height: height)
            sheen.colors = [
                UIColor.clear.cgColor,
                UIColor.white.withAlphaComponent(0.03).cgColor,
                UIColor(displayP3Red: 0.52, green: 0.90, blue: 1, alpha: 0.28).cgColor,
                UIColor(displayP3Red: 0.20, green: 0.82, blue: 1, alpha: 0.17).cgColor,
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

        // A separate iridescent reflection crosses the lower magenta surface
        // slightly later. Both passes use the exact original alpha silhouette.
        func addPrismaticReflection(to group: CALayer) -> CAGradientLayer {
            let sleeve = CALayer()
            sleeve.frame = canvas
            sleeve.mask = artworkAlphaMask()
            group.addSublayer(sleeve)

            let sheen = CAGradientLayer()
            sheen.frame = CGRect(
                x: -width * 0.65, y: height * 0.31,
                width: width * 0.53, height: height * 0.66
            )
            sheen.colors = [
                UIColor.clear.cgColor,
                UIColor(displayP3Red: 0.32, green: 0.84, blue: 1, alpha: 0.06).cgColor,
                UIColor(displayP3Red: 0.97, green: 0.39, blue: 0.90, alpha: 0.31).cgColor,
                UIColor(displayP3Red: 0.96, green: 0.28, blue: 1, alpha: 0.13).cgColor,
                UIColor.clear.cgColor
            ]
            sheen.locations = [0, 0.36, 0.50, 0.64, 1]
            sheen.startPoint = CGPoint(x: 0.1, y: 0)
            sheen.endPoint = CGPoint(x: 0.9, y: 1)
            sheen.opacity = 0
            sleeve.addSublayer(sheen)
            return sheen
        }
        let prism = addPrismaticReflection(to: logoGroup)
        let mirrorPrism = addPrismaticReflection(to: reflectedGroup)

        // The travelling drawing head is narrow and clipped to the existing
        // artwork. Its glow is created by a shadow on that same stroked path;
        // it never paints a new flat Z or lights the empty background.
        let headSleeve = CALayer()
        headSleeve.frame = canvas
        headSleeve.mask = artworkAlphaMask()
        logoGroup.addSublayer(headSleeve)

        let drawHead = CAShapeLayer()
        drawHead.frame = canvas
        drawHead.path = centerline
        drawHead.fillColor = nil
        drawHead.strokeColor = UIColor(
            displayP3Red: 0.86, green: 0.97, blue: 1, alpha: 1
        ).cgColor
        drawHead.lineWidth = 5.5 * scale
        drawHead.lineCap = .round
        drawHead.lineJoin = .round
        drawHead.strokeStart = 0
        drawHead.strokeEnd = 0
        drawHead.opacity = reduceMotion ? 0 : 1
        drawHead.shadowColor = UIColor(
            displayP3Red: 0.12, green: 0.87, blue: 1, alpha: 1
        ).cgColor
        drawHead.shadowOpacity = 0.42
        drawHead.shadowRadius = 11 * scale
        drawHead.shadowOffset = .zero
        headSleeve.addSublayer(drawHead)

        // The crisp logo resolves from a softly luminous copy. A static
        // pre-rasterised glow layer avoids a costly animated Gaussian blur.
        let focusAura = CALayer()
        focusAura.frame = canvas
        focusAura.contents = artwork
        focusAura.contentsGravity = .resizeAspect
        focusAura.contentsScale = UIScreen.main.scale
        focusAura.shadowColor = UIColor(
            displayP3Red: 0.43, green: 0.68, blue: 1, alpha: 1
        ).cgColor
        focusAura.shadowOpacity = 0.18
        focusAura.shadowRadius = 12 * scale
        focusAura.shadowOffset = .zero
        focusAura.opacity = reduceMotion ? 0 : 0
        logoGroup.insertSublayer(focusAura, below: drawnZ)

        // Three separately laid-out CATextLayers: no typewriter wipe, no
        // awkward partial letters. Each word arrives with a clean rise, glow
        // and a short specular pass. Keep the whole line optically centred.
        let mottoFontSize = min(21, max(16.5, bounds.width * 0.049))
        let words = ["Sideloading", "and", "beyond."]
        // Editorial typographic contrast: an airy opening, restrained
        // connector, and a confident finishing word. Not three identical
        // system-font labels with a generic shine.
        let weights: [UIFont.Weight] = [.light, .ultraLight, .semibold]
        let tracking: [CGFloat] = [0.9, 1.15, 0.65]
        let gap: CGFloat = max(10, mottoFontSize * 0.52)
        let measured = words.enumerated().map { index, word in
            let font = UIFont.systemFont(ofSize: mottoFontSize, weight: weights[index])
            let base = (word as NSString).size(withAttributes: [.font: font]).width
            return ceil(base + tracking[index] * CGFloat(word.count - 1))
        }
        let lineWidth = measured.reduce(0, +) + gap * CGFloat(words.count - 1)
        let fit = min(1, (bounds.width - 30) / lineWidth)
        let wordY = max(
            logoRect.maxY + reflectionHeight + 28,
            bounds.height * 0.681
        )
        var wordX = (bounds.width - lineWidth * fit) / 2
        var wordLayers: [CATextLayer] = []
        var wordSheens: [CAGradientLayer] = []

        for (index, word) in words.enumerated() {
            let wordWidth = measured[index] * fit
            let text = CATextLayer()
            text.contentsScale = UIScreen.main.scale
            text.alignmentMode = .center
            text.isWrapped = false
            text.truncationMode = .none
            text.string = NSAttributedString(
                string: word,
                attributes: [
                    .font: UIFont.systemFont(
                        ofSize: mottoFontSize * fit,
                        weight: weights[index]
                    ),
                    .foregroundColor: UIColor.white.withAlphaComponent(
                        index == 1 ? 0.68 : 0.96
                    ),
                    .kern: tracking[index] * fit
                ]
            )
            text.frame = CGRect(
                x: wordX, y: wordY,
                width: wordWidth + 2,
                height: mottoFontSize * fit * 1.7
            )
            text.opacity = reduceMotion ? 1 : 0
            layer.addSublayer(text)
            wordLayers.append(text)

            // White-gold reflection is confined to the glyphs of this word.
            let sleeve = CALayer()
            sleeve.frame = text.frame
            let glyphMask = CATextLayer()
            glyphMask.frame = sleeve.bounds
            glyphMask.contentsScale = UIScreen.main.scale
            glyphMask.alignmentMode = .center
            glyphMask.string = text.string
            sleeve.mask = glyphMask
            layer.addSublayer(sleeve)

            let sheen = CAGradientLayer()
            sheen.frame = CGRect(
                x: -wordWidth * 0.85, y: 0,
                width: wordWidth * 0.65,
                height: sleeve.bounds.height
            )
            sheen.colors = [
                UIColor.clear.cgColor,
                UIColor.white.withAlphaComponent(0.04).cgColor,
                UIColor.white.withAlphaComponent(0.30).cgColor,
                UIColor.clear.cgColor
            ]
            sheen.locations = [0, 0.32, 0.55, 1]
            sheen.startPoint = CGPoint(x: 0, y: 0)
            sheen.endPoint = CGPoint(x: 1, y: 0.25)
            sheen.opacity = 0
            sleeve.addSublayer(sheen)
            wordSheens.append(sheen)
            wordX += wordWidth + gap * fit
        }

        guard !reduceMotion else {
            CATransaction.commit()
            return
        }

        // One uninterrupted, cubic-eased stroke. The three bars are one
        // continuous CGPath and the drawing head uses the identical clock.
        // This removes the stops and visual 'pop-in' at the two corners.
        func animateDraw(_ mask: CAShapeLayer) {
            mask.strokeEnd = 1
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.beginTime = tick + 0.20
            draw.duration = 1.60
            draw.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.35, 0.04, 0.20, 1
            )
            draw.fillMode = .both
            draw.isRemovedOnCompletion = false
            mask.add(draw, forKey: "zag.continuousReveal")
        }
        animateDraw(drawMask)
        animateDraw(reflectionMask)

        // A continuous leading energy tip with a short travelling tail.
        // The same easing/duration as the mask keeps both in phase.
        let headEase = CAMediaTimingFunction(
            controlPoints: 0.35, 0.04, 0.20, 1
        )
        let headStart = CABasicAnimation(keyPath: "strokeStart")
        headStart.fromValue = 0
        headStart.toValue = 0.977
        headStart.beginTime = tick + 0.20
        headStart.duration = 1.60
        headStart.timingFunction = headEase
        headStart.fillMode = .both
        headStart.isRemovedOnCompletion = false
        drawHead.add(headStart, forKey: "zag.drawHeadTail")

        let headEnd = CABasicAnimation(keyPath: "strokeEnd")
        headEnd.fromValue = 0.023
        headEnd.toValue = 1
        headEnd.beginTime = tick + 0.20
        headEnd.duration = 1.60
        headEnd.timingFunction = headEase
        headEnd.fillMode = .both
        headEnd.isRemovedOnCompletion = false
        drawHead.add(headEnd, forKey: "zag.drawHeadTip")

        let headDissolve = CAKeyframeAnimation(keyPath: "opacity")
        headDissolve.values = [0, 0.72, 0.72, 0]
        headDissolve.keyTimes = [0, 0.10, 0.83, 1]
        headDissolve.beginTime = tick + 0.20
        headDissolve.duration = 1.65
        headDissolve.fillMode = .both
        headDissolve.isRemovedOnCompletion = false
        drawHead.opacity = 0
        drawHead.add(headDissolve, forKey: "zag.drawHeadGlow")

        func animateFullArtwork(_ finished: CALayer, _ drawing: CALayer) {
            finished.opacity = 1
            drawing.opacity = 0
            let arrive = CABasicAnimation(keyPath: "opacity")
            arrive.fromValue = 0
            arrive.toValue = 1
            arrive.beginTime = tick + 1.73
            arrive.duration = 0.24
            arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arrive.fillMode = .both
            arrive.isRemovedOnCompletion = false
            finished.add(arrive, forKey: "zag.complete")

            let retire = CABasicAnimation(keyPath: "opacity")
            retire.fromValue = 1
            retire.toValue = 0
            retire.beginTime = tick + 1.73
            retire.duration = 0.24
            retire.fillMode = .both
            retire.isRemovedOnCompletion = false
            drawing.add(retire, forKey: "zag.retireMask")
        }
        animateFullArtwork(completeZ, drawnZ)
        animateFullArtwork(reflectionComplete, reflectionDraw)

        glow.opacity = 0.20
        let bloom = CAKeyframeAnimation(keyPath: "opacity")
        bloom.values = [0.02, 0.10, 0.28, 0.18, 0.20]
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

        // Colour develops with the geometry: cyan wakes first at the upper
        // stroke; magenta blooms later when the lower bar materialises.
        func animateColour(
            _ layer: CAGradientLayer,
            values: [NSNumber],
            times: [NSNumber]
        ) {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = values
            pulse.keyTimes = times
            pulse.beginTime = tick + 0.18
            pulse.duration = 2.34
            pulse.fillMode = .both
            pulse.isRemovedOnCompletion = false
            layer.opacity = 1
            layer.add(pulse, forKey: "zag.colourResponse")
        }
        animateColour(
            cyanBloom,
            values: [0.20, 0.72, 0.64, 0.54],
            times: [0, 0.22, 0.67, 1]
        )
        animateColour(
            magentaBloom,
            values: [0.03, 0.12, 0.75, 0.56],
            times: [0, 0.30, 0.72, 1]
        )

        focusAura.opacity = 0
        let clarity = CAKeyframeAnimation(keyPath: "opacity")
        clarity.values = [0, 0.09, 0.17, 0]
        clarity.keyTimes = [0, 0.48, 0.75, 1]
        clarity.beginTime = tick + 0.34
        clarity.duration = 1.92
        clarity.fillMode = .both
        clarity.isRemovedOnCompletion = false
        focusAura.add(clarity, forKey: "zag.opticalFocus")

        reflectedWindow.opacity = 0.82
        let reflectionFadeIn = CABasicAnimation(keyPath: "opacity")
        reflectionFadeIn.fromValue = 0
        reflectionFadeIn.toValue = 0.82
        reflectionFadeIn.beginTime = tick + 0.42
        reflectionFadeIn.duration = 1.50
        reflectionFadeIn.fillMode = .both
        reflectionFadeIn.isRemovedOnCompletion = false
        reflectionFadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        reflectedWindow.add(reflectionFadeIn, forKey: "zag.reflectionLive")

        // Both the logo and its actual mirror receive the travelling beam.
        func animateSheen(_ sheen: CALayer) {
            let travel = CABasicAnimation(keyPath: "position.x")
            travel.fromValue = -width * 0.44
            travel.toValue = width * 1.30
            travel.beginTime = tick + 1.40
            travel.duration = 1.02
            travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            travel.fillMode = .both
            travel.isRemovedOnCompletion = false
            sheen.position.x = width * 1.30
            sheen.add(travel, forKey: "zag.specularTravel")

            let amplitude = CAKeyframeAnimation(keyPath: "opacity")
            amplitude.values = [0, 0.46, 0.40, 0]
            amplitude.keyTimes = [0, 0.24, 0.72, 1]
            amplitude.beginTime = tick + 1.40
            amplitude.duration = 1.02
            amplitude.fillMode = .both
            amplitude.isRemovedOnCompletion = false
            sheen.opacity = 0
            sheen.add(amplitude, forKey: "zag.specularGlow")
        }
        animateSheen(specular)
        animateSheen(mirrorSpecular)

        // The second highlight is offset in time and restricted to the lower
        // portion of the genuine logo. The reflected copy moves identically.
        func animatePrism(_ sheen: CAGradientLayer) {
            let travel = CABasicAnimation(keyPath: "position.x")
            travel.fromValue = -width * 0.42
            travel.toValue = width * 1.21
            travel.beginTime = tick + 1.74
            travel.duration = 0.86
            travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            travel.fillMode = .both
            travel.isRemovedOnCompletion = false
            sheen.position.x = width * 1.21
            sheen.add(travel, forKey: "zag.prismTravel")

            let light = CAKeyframeAnimation(keyPath: "opacity")
            light.values = [0, 0.43, 0.38, 0]
            light.keyTimes = [0, 0.22, 0.70, 1]
            light.beginTime = tick + 1.74
            light.duration = 0.86
            light.fillMode = .both
            light.isRemovedOnCompletion = false
            sheen.add(light, forKey: "zag.prismLight")
        }
        animatePrism(prism)
        animatePrism(mirrorPrism)

        // Delayed, individual word reveals. Each word fades and rises
        // into its final baseline; its light sweep follows the entrance.
        // The final phrase is held as a composed hero frame before fade-out.
        for (index, word) in wordLayers.enumerated() {
            let arrival = tick + 1.94 + Double(index) * 0.24
            word.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = arrival
            fade.duration = 0.45
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            word.add(fade, forKey: "zag.wordFade")

            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = word.position.y + 5
            rise.toValue = word.position.y
            rise.beginTime = arrival
            rise.duration = 0.52
            rise.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.18, 0.75, 0.26, 1
            )
            rise.fillMode = .both
            rise.isRemovedOnCompletion = false
            word.add(rise, forKey: "zag.wordRise")

            let sheen = wordSheens[index]
            let pass = CABasicAnimation(keyPath: "position.x")
            pass.fromValue = -sheen.bounds.width
            pass.toValue = word.bounds.width + sheen.bounds.width
            pass.beginTime = arrival + 0.16
            pass.duration = 0.52
            pass.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pass.fillMode = .both
            pass.isRemovedOnCompletion = false
            sheen.add(pass, forKey: "zag.wordLightTravel")

            let flare = CAKeyframeAnimation(keyPath: "opacity")
            flare.values = [0, 0.34, 0.34, 0]
            flare.keyTimes = [0, 0.24, 0.72, 1]
            flare.beginTime = arrival + 0.16
            flare.duration = 0.52
            flare.fillMode = .both
            flare.isRemovedOnCompletion = false
            sheen.add(flare, forKey: "zag.wordLight")
        }

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
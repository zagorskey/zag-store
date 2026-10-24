//
// ZagSplashAnimationStage.swift
// Zag Store — original-artwork cinematic cold start.
//
// The Z is always the user's original ZagSplashZIsolated bitmap. Vector
// geometry is only an alpha REVEAL; never a second logo or a colour substitute.
// A single master clock drives lighting, reflection, typography and exit.
//

import SwiftUI
import UIKit
import QuartzCore

/// Source of truth for the on-device choreography and SwiftUI handoff.
/// Absolute seconds from the runtime splash's initial frame.
enum ZagSplashTimeline {
    static let ignition: Double = 0.24
    static let drawing: Double = 0.30
    static let drawDuration: Double = 1.43
    static let resolve: Double = 1.64
    static let resolveDuration: Double = 0.25
    static let studioLight: Double = 1.34
    static let studioDuration: Double = 0.90
    static let firstWord: Double = 1.92
    static let wordStagger: Double = 0.25
    static let wordDuration: Double = 0.46
    static let heroHoldEnd: Double = 3.16
    static let exitDuration: Double = 0.44
    static let screenFadeStart: Double = 3.54
    static let screenFadeDuration: Double = 0.34
    static let finish: Double = 3.92
}

struct ZagSplashAnimationStage: UIViewRepresentable {
    let reduceMotion: Bool
    let exiting: Bool

    func makeUIView(context: Context) -> ZagSplashStageView {
        ZagSplashStageView(reduceMotion: reduceMotion)
    }

    func updateUIView(_ uiView: ZagSplashStageView, context: Context) {
        if exiting {
            uiView.beginExit()
        }
    }
}

final class ZagSplashStageView: UIView {
    private let reduceMotion: Bool
    private let backdrop = UIImageView(image: UIImage(named: "ZagSplashBackdrop"))
    private var assembled = false
    private var exitStarted = false
    private var logo: CALayer?
    private var reflectedWindow: CALayer?
    private var ambient: CALayer?
    private var words: [CATextLayer] = []
    private var wordLights: [CAGradientLayer] = []

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 4.0 / 255.0, green: 6.0 / 255.0, blue: 18.0 / 255.0, alpha: 1)
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        // Matches the alpha-darkened storyboard's initial gradient frame.
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
        guard let originalZ = UIImage(named: "ZagSplashZIsolated")?.cgImage else {
            // Never substitute or redraw missing brand artwork.
            return
        }
        let w = min(bounds.width * 0.665, 304)
        let h = w * CGFloat(originalZ.height) / CGFloat(originalZ.width)
        let rect = CGRect(
            x: (bounds.width - w) / 2,
            y: bounds.height * 0.420 - h / 2,
            width: w,
            height: h
        )
        let canvas = CGRect(origin: .zero, size: rect.size)
        let scale = w / 692
        let clock = CACurrentMediaTime() + 0.05

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // A quiet midnight stage. The logo itself creates the coloured light.
        let atmosphere = CALayer()
        atmosphere.frame = rect.insetBy(dx: -w * 0.35, dy: -h * 0.35)
        atmosphere.opacity = reduceMotion ? 0.14 : 0
        layer.addSublayer(atmosphere)
        ambient = atmosphere

        func bloom(_ colour: UIColor, x: CGFloat, strength: CGFloat) -> CAGradientLayer {
            let light = CAGradientLayer()
            light.type = .radial
            light.frame = atmosphere.bounds
            light.startPoint = CGPoint(x: x, y: 0.48)
            light.endPoint = CGPoint(x: x + 0.46, y: 0.96)
            light.colors = [
                colour.withAlphaComponent(strength).cgColor,
                colour.withAlphaComponent(strength * 0.26).cgColor,
                UIColor.clear.cgColor
            ]
            light.locations = [0, 0.46, 1]
            atmosphere.addSublayer(light)
            return light
        }
        let cyan = bloom(
            UIColor(displayP3Red: 0, green: 0.75, blue: 1, alpha: 1),
            x: 0.34, strength: 0.20
        )
        let violet = bloom(
            UIColor(displayP3Red: 0.82, green: 0.18, blue: 1, alpha: 1),
            x: 0.65, strength: 0.16
        )

        // Crop the mirror to its near-surface reflection; the same drawing
        // and studio-light timetable governs both Z and reflected Z.
        let mirrorHeight = min(h * 0.27, 82)
        let reflection = CALayer()
        reflection.frame = CGRect(
            x: rect.minX, y: rect.maxY + 5,
            width: w, height: mirrorHeight
        )
        reflection.masksToBounds = true
        reflection.opacity = reduceMotion ? 0.42 : 0
        layer.addSublayer(reflection)
        reflectedWindow = reflection

        let mirrorFade = CAGradientLayer()
        mirrorFade.frame = reflection.bounds
        mirrorFade.colors = [
            UIColor.white.withAlphaComponent(0.58).cgColor,
            UIColor.white.withAlphaComponent(0.21).cgColor,
            UIColor.clear.cgColor
        ]
        mirrorFade.locations = [0, 0.33, 1]
        mirrorFade.startPoint = CGPoint(x: 0.5, y: 0)
        mirrorFade.endPoint = CGPoint(x: 0.5, y: 1)
        reflection.mask = mirrorFade

        let mirror = CALayer()
        mirror.frame = canvas
        mirror.transform = CATransform3DMakeScale(1, -1, 1)
        reflection.addSublayer(mirror)

        let markGroup = CALayer()
        markGroup.frame = rect
        layer.addSublayer(markGroup)
        logo = markGroup

        func originalImage(in group: CALayer, alpha: Float) -> CALayer {
            let mark = CALayer()
            mark.frame = canvas
            mark.contents = originalZ
            mark.contentsGravity = .resizeAspect
            mark.contentsScale = UIScreen.main.scale
            mark.minificationFilter = .trilinear
            mark.magnificationFilter = .linear
            mark.opacity = alpha
            group.addSublayer(mark)
            return mark
        }

        func alphaMask() -> CALayer {
            let mask = CALayer()
            mask.frame = canvas
            mask.contents = originalZ
            mask.contentsGravity = .resizeAspect
            mask.contentsScale = UIScreen.main.scale
            return mask
        }

        // The path NEVER supplies the visible logo: it is merely a generous
        // progressive alpha envelope around the existing translucent pixels.
        let path = UIBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scale, y: y * scale)
        }
        path.move(to: p(132, 116))
        path.addLine(to: p(580, 116))
        path.addLine(to: p(130, 601))
        path.addLine(to: p(580, 601))
        let zPath = path.cgPath

        func revealMask(_ image: CALayer) -> CAShapeLayer {
            let mask = CAShapeLayer()
            mask.frame = canvas
            mask.path = zPath
            mask.fillColor = nil
            mask.strokeColor = UIColor.white.cgColor
            mask.lineWidth = 268 * scale
            mask.lineCap = .round
            mask.lineJoin = .round
            mask.strokeEnd = reduceMotion ? 1 : 0
            image.mask = mask
            return mask
        }

        let drawnMark = originalImage(in: markGroup, alpha: 1)
        let drawMask = revealMask(drawnMark)
        let finishedMark = originalImage(in: markGroup, alpha: reduceMotion ? 1 : 0)
        let mirrorDraw = originalImage(in: mirror, alpha: 1)
        let mirrorMask = revealMask(mirrorDraw)
        let mirrorFinish = originalImage(in: mirror, alpha: reduceMotion ? 1 : 0)

        // One intentionally orchestrated studio reflection, masked to the
        // ORIGINAL Z pixels. Colours complement the art instead of whitening it.
        func studioReflection(in group: CALayer) -> CAGradientLayer {
            let sleeve = CALayer()
            sleeve.frame = canvas
            sleeve.mask = alphaMask()
            group.addSublayer(sleeve)

            let light = CAGradientLayer()
            light.frame = CGRect(
                x: -w * 0.60, y: -h * 0.04,
                width: w * 0.54, height: h * 1.08
            )
            light.colors = [
                UIColor.clear.cgColor,
                UIColor(displayP3Red: 0.10, green: 0.76, blue: 1, alpha: 0.04).cgColor,
                UIColor(displayP3Red: 0.50, green: 0.92, blue: 1, alpha: 0.34).cgColor,
                UIColor(displayP3Red: 0.90, green: 0.34, blue: 0.98, alpha: 0.21).cgColor,
                UIColor.clear.cgColor
            ]
            light.locations = [0, 0.34, 0.49, 0.63, 1]
            light.startPoint = CGPoint(x: 0.08, y: 0)
            light.endPoint = CGPoint(x: 0.92, y: 1)
            light.opacity = 0
            sleeve.addSublayer(light)
            return light
        }
        let studio = studioReflection(in: markGroup)
        let mirroredStudio = studioReflection(in: mirror)

        // A small coloured ignition within the top-left rounded end.
        // It is not a second path or a cartoon starburst.
        let sparkSleeve = CALayer()
        sparkSleeve.frame = canvas
        sparkSleeve.mask = alphaMask()
        markGroup.addSublayer(sparkSleeve)

        let energy = CAShapeLayer()
        energy.frame = canvas
        energy.path = zPath
        energy.fillColor = nil
        energy.strokeColor = UIColor(
            displayP3Red: 0.28, green: 0.84, blue: 1, alpha: 0.44
        ).cgColor
        energy.lineWidth = 12 * scale
        energy.lineCap = .round
        energy.lineJoin = .round
        energy.strokeStart = 0
        energy.strokeEnd = 0
        energy.opacity = reduceMotion ? 0 : 1
        energy.shadowColor = UIColor(
            displayP3Red: 0.00, green: 0.76, blue: 1, alpha: 1
        ).cgColor
        energy.shadowRadius = 12 * scale
        energy.shadowOpacity = 0.52
        energy.shadowOffset = .zero
        sparkSleeve.addSublayer(energy)

        // The motto is editorial: three aligned words, separately animated,
        // with hierarchy in weight/tracking rather than large glowing labels.
        let captionSize = min(20, max(16.5, bounds.width * 0.0475))
        let tokens = ["Sideloading", "and", "beyond."]
        let weight: [UIFont.Weight] = [.light, .ultraLight, .semibold]
        let kern: [CGFloat] = [1.0, 1.1, 0.45]
        let gap: CGFloat = max(9, captionSize * 0.48)
        let measured: [CGFloat] = tokens.enumerated().map { i, word in
            let font = UIFont.systemFont(ofSize: captionSize, weight: weight[i])
            let textWidth = (word as NSString).size(withAttributes: [.font: font]).width
            return ceil(textWidth + CGFloat(word.count - 1) * kern[i])
        }
        let textWidth = measured.reduce(0, +) + CGFloat(tokens.count - 1) * gap
        let fit = min(1, (bounds.width - 28) / textWidth)
        let baselineY = max(rect.maxY + mirrorHeight + 28, bounds.height * 0.675)
        var cursorX = (bounds.width - fit * textWidth) / 2

        for (index, word) in tokens.enumerated() {
            let font = UIFont.systemFont(ofSize: captionSize * fit, weight: weight[index])
            let tokenWidth = measured[index] * fit
            let text = CATextLayer()
            text.contentsScale = UIScreen.main.scale
            text.alignmentMode = .center
            text.isWrapped = false
            text.truncationMode = .none
            text.string = NSAttributedString(
                string: word,
                attributes: [
                    .font: font,
                    .foregroundColor: UIColor.white.withAlphaComponent(index == 1 ? 0.70 : 0.95),
                    .kern: kern[index] * fit
                ]
            )
            text.frame = CGRect(
                x: cursorX, y: baselineY,
                width: tokenWidth + 2, height: captionSize * fit * 1.75
            )
            text.opacity = reduceMotion ? 1 : 0
            layer.addSublayer(text)
            words.append(text)
            cursorX += tokenWidth + gap * fit

            // A tiny pass across each glyph group, never a permanent glow.
            let glyphClip = CATextLayer()
            glyphClip.frame = text.bounds
            glyphClip.contentsScale = UIScreen.main.scale
            glyphClip.alignmentMode = .center
            glyphClip.string = text.string

            let sleeve = CALayer()
            sleeve.frame = text.frame
            sleeve.mask = glyphClip
            layer.addSublayer(sleeve)

            let glint = CAGradientLayer()
            glint.frame = CGRect(
                x: -tokenWidth * 0.65, y: 0,
                width: tokenWidth * 0.55, height: sleeve.bounds.height
            )
            glint.colors = [
                UIColor.clear.cgColor,
                UIColor.white.withAlphaComponent(0.02).cgColor,
                UIColor.white.withAlphaComponent(0.27).cgColor,
                UIColor.clear.cgColor
            ]
            glint.locations = [0, 0.35, 0.55, 1]
            glint.opacity = 0
            sleeve.addSublayer(glint)
            wordLights.append(glint)
        }

        if reduceMotion {
            CATransaction.commit()
            return
        }

        func opacityKeys(
            _ target: CALayer,
            values: [NSNumber],
            times: [NSNumber],
            from: Double,
            duration: Double,
            id: String,
            ending: Float
        ) {
            target.opacity = ending
            let key = CAKeyframeAnimation(keyPath: "opacity")
            key.values = values
            key.keyTimes = times
            key.beginTime = clock + from
            key.duration = duration
            key.fillMode = .both
            key.isRemovedOnCompletion = false
            target.add(key, forKey: id)
        }

        // 1. IGNITION — light originates inside the real glass surfaces.
        opacityKeys(
            atmosphere,
            values: [0, 0.20, 0.36, 0.19],
            times: [0, 0.25, 0.70, 1],
            from: ZagSplashTimeline.ignition,
            duration: 2.32, id: "zag.ambientBreath", ending: 0.19
        )
        opacityKeys(
            cyan,
            values: [0.30, 0.90, 0.72, 0.60],
            times: [0, 0.21, 0.71, 1],
            from: ZagSplashTimeline.ignition,
            duration: 2.32, id: "zag.cyan", ending: 0.60
        )
        opacityKeys(
            violet,
            values: [0.06, 0.13, 0.87, 0.66],
            times: [0, 0.34, 0.75, 1],
            from: ZagSplashTimeline.ignition,
            duration: 2.32, id: "zag.magenta", ending: 0.66
        )

        // 2. REVELATION — a single, uninterrupted draw across all three
        // segments. The actual alpha PNG resolves unmodified at the end.
        let ease = CAMediaTimingFunction(controlPoints: 0.34, 0.04, 0.21, 1)
        func animateStroke(_ shape: CAShapeLayer) {
            shape.strokeEnd = 1
            let trim = CABasicAnimation(keyPath: "strokeEnd")
            trim.fromValue = 0
            trim.toValue = 1
            trim.beginTime = clock + ZagSplashTimeline.drawing
            trim.duration = ZagSplashTimeline.drawDuration
            trim.timingFunction = ease
            trim.fillMode = .both
            trim.isRemovedOnCompletion = false
            shape.add(trim, forKey: "zag.reveal")
        }
        animateStroke(drawMask)
        animateStroke(mirrorMask)

        energy.strokeStart = 0.972
        energy.strokeEnd = 1
        let headTail = CABasicAnimation(keyPath: "strokeStart")
        headTail.fromValue = 0
        headTail.toValue = 0.972
        headTail.beginTime = clock + ZagSplashTimeline.drawing
        headTail.duration = ZagSplashTimeline.drawDuration
        headTail.timingFunction = ease
        headTail.fillMode = .both
        headTail.isRemovedOnCompletion = false
        energy.add(headTail, forKey: "zag.energyTail")

        let headTip = CABasicAnimation(keyPath: "strokeEnd")
        headTip.fromValue = 0.028
        headTip.toValue = 1
        headTip.beginTime = clock + ZagSplashTimeline.drawing
        headTip.duration = ZagSplashTimeline.drawDuration
        headTip.timingFunction = ease
        headTip.fillMode = .both
        headTip.isRemovedOnCompletion = false
        energy.add(headTip, forKey: "zag.energyTip")
        opacityKeys(
            energy, values: [0, 0.82, 0.76, 0],
            times: [0, 0.12, 0.80, 1],
            from: ZagSplashTimeline.drawing,
            duration: ZagSplashTimeline.drawDuration + 0.08,
            id: "zag.energyIntensity", ending: 0
        )

        func finishReveal(_ finished: CALayer, _ drawing: CALayer) {
            finished.opacity = 1
            drawing.opacity = 0
            let arrive = CABasicAnimation(keyPath: "opacity")
            arrive.fromValue = 0
            arrive.toValue = 1
            arrive.beginTime = clock + ZagSplashTimeline.resolve
            arrive.duration = ZagSplashTimeline.resolveDuration
            arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arrive.fillMode = .both
            arrive.isRemovedOnCompletion = false
            finished.add(arrive, forKey: "zag.fullArtwork")

            let dissolve = CABasicAnimation(keyPath: "opacity")
            dissolve.fromValue = 1
            dissolve.toValue = 0
            dissolve.beginTime = arrive.beginTime
            dissolve.duration = arrive.duration
            dissolve.fillMode = .both
            dissolve.isRemovedOnCompletion = false
            drawing.add(dissolve, forKey: "zag.revealDeparture")
        }
        finishReveal(finishedMark, drawnMark)
        finishReveal(mirrorFinish, mirrorDraw)

        opacityKeys(
            reflection,
            values: [0, 0.18, 0.49, 0.52],
            times: [0, 0.22, 0.75, 1],
            from: ZagSplashTimeline.drawing,
            duration: 1.78, id: "zag.reflectionRise", ending: 0.52
        )

        // A very small dimensional settle, not a bounce or a 3D rotation.
        let settle = CABasicAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.986
        settle.toValue = 1
        settle.beginTime = clock + ZagSplashTimeline.ignition
        settle.duration = 2.12
        settle.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.19, 0.68, 0.29, 1
        )
        settle.fillMode = .both
        settle.isRemovedOnCompletion = false
        markGroup.add(settle, forKey: "zag.focusLock")

        // 3. REVELATION OF LIGHT — one moving studio source, same source
        // timing for its floor reflection. Vivid glass remains untouched.
        func animateStudio(_ light: CAGradientLayer) {
            light.position.x = w * 1.31
            let travel = CABasicAnimation(keyPath: "position.x")
            travel.fromValue = -w * 0.31
            travel.toValue = w * 1.31
            travel.beginTime = clock + ZagSplashTimeline.studioLight
            travel.duration = ZagSplashTimeline.studioDuration
            travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            travel.fillMode = .both
            travel.isRemovedOnCompletion = false
            light.add(travel, forKey: "zag.studioTravel")
            opacityKeys(
                light, values: [0, 0.63, 0.59, 0],
                times: [0, 0.20, 0.72, 1],
                from: ZagSplashTimeline.studioLight,
                duration: ZagSplashTimeline.studioDuration,
                id: "zag.studioGlint", ending: 0
            )
        }
        animateStudio(studio)
        animateStudio(mirroredStudio)

        // 4. SIGNATURE — three words, precisely timed to the logo's
        // completion. Optical clarity and typographic hierarchy do the work.
        for (index, text) in words.enumerated() {
            let arrival = ZagSplashTimeline.firstWord
                + Double(index) * ZagSplashTimeline.wordStagger
            text.opacity = 1
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = clock + arrival
            appear.duration = ZagSplashTimeline.wordDuration
            appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
            appear.fillMode = .both
            appear.isRemovedOnCompletion = false
            text.add(appear, forKey: "zag.wordAppear")

            let focus = CABasicAnimation(keyPath: "position.y")
            focus.fromValue = text.position.y + 4
            focus.toValue = text.position.y
            focus.beginTime = appear.beginTime
            focus.duration = appear.duration
            focus.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.18, 0.72, 0.27, 1
            )
            focus.fillMode = .both
            focus.isRemovedOnCompletion = false
            text.add(focus, forKey: "zag.wordFocus")

            let glint = wordLights[index]
            glint.position.x = text.bounds.width + glint.bounds.width
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -glint.bounds.width
            move.toValue = glint.position.x
            move.beginTime = clock + arrival + 0.12
            move.duration = 0.44
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            move.fillMode = .both
            move.isRemovedOnCompletion = false
            glint.add(move, forKey: "zag.wordSweep")
            opacityKeys(
                glint, values: [0, 0.39, 0.32, 0],
                times: [0, 0.24, 0.73, 1],
                from: arrival + 0.12,
                duration: 0.44, id: "zag.wordCatch", ending: 0
            )
        }
        CATransaction.commit()
    }

    /// 5. EXIT — stagger the departure. Only the Z remains for the last
    /// fraction of a second before SwiftUI crossfades the dark stage away.
    func beginExit() {
        guard !exitStarted, assembled, !reduceMotion else { return }
        exitStarted = true
        let duration = ZagSplashTimeline.exitDuration

        func fade(_ target: CALayer?, delay: Double, length: Double) {
            guard let target else { return }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = target.presentation()?.opacity ?? target.opacity
            animation.toValue = 0
            animation.duration = length
            animation.beginTime = CACurrentMediaTime() + delay
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            target.opacity = 0
            target.add(animation, forKey: "zag.exit")
        }
        fade(ambient, delay: 0, length: 0.22)
        fade(reflectedWindow, delay: 0.04, length: 0.25)
        for (index, word) in words.enumerated().reversed() {
            fade(word, delay: 0.05 + Double(2 - index) * 0.035, length: 0.20)
        }
        fade(logo, delay: 0.20, length: max(0.17, duration - 0.20))
    }
}

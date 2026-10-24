//
// ZagCinematicSplashView.swift
// Zag Store's cinematic launch. Original Kling master video is not recoloured,
// re-rendered or filtered. All lettering is separately native/Core Animation.
//

import SwiftUI
import UIKit
import AVFoundation
import QuartzCore

struct ZagCinematicSplashView: UIViewRepresentable {
    let soundEnabled: Bool
    let onFinished: () -> Void

    func makeUIView(context: Context) -> ZagCinematicSplashStage {
        let view = ZagCinematicSplashStage()
        view.onFinished = onFinished
        view.soundEnabled = soundEnabled
        return view
    }

    func updateUIView(_ uiView: ZagCinematicSplashStage, context: Context) {
        uiView.onFinished = onFinished
        uiView.soundEnabled = soundEnabled
    }

    static var available: Bool {
        Bundle.main.url(
            forResource: "ZagSplashCinematic",
            withExtension: "mp4"
        ) != nil
    }
}

final class ZagCinematicSplashStage: UIView {
    var onFinished: (() -> Void)?
    var soundEnabled: Bool = true {
        didSet {
            player?.isMuted = !soundEnabled
        }
    }

    private let backgroundImage = UIImageView(image: UIImage(named: "ZagSplashBackdrop"))
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playbackClock: Any?
    private var endObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var itemStatus: NSKeyValueObservation?
    private var started = false
    private var finished = false
    private var prepared = false
    private var wordLayers: [CATextLayer] = []
    private var wordGlints: [CAGradientLayer] = []
    private var revealed = [false, false, false]
    private var sweep: CAGradientLayer?
    private var sweepRange = CGRect.zero
    private var startedSweep = false

    // Timed against the PLAYER rather than wall-clock time. Buffering or
    // device startup delay never separates the motto from its video cue.
    private let arrivalTimes: [Double] = [2.48, 3.05, 3.51]
    private let videoDuration: Double = 5.041667

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 3/255, green: 5/255, blue: 15/255, alpha: 1)
        clipsToBounds = true
        backgroundImage.contentMode = .scaleAspectFill
        backgroundImage.clipsToBounds = true
        backgroundImage.alpha = 0.52
        addSubview(backgroundImage)
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 20, bounds.height > 20 else { return }
        backgroundImage.frame = bounds
        playerLayer?.frame = bounds
        if !prepared {
            prepared = true
            prepare()
        }
        if !started, window != nil {
            start()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, prepared, !started {
            start()
        } else if window == nil {
            player?.pause()
        }
    }

    private func prepare() {
        guard let url = Bundle.main.url(
            forResource: "ZagSplashCinematic",
            withExtension: "mp4"
        ) else {
            finish()
            return
        }

        let item = AVPlayerItem(url: url)
        let videoPlayer = AVPlayer(playerItem: item)
        videoPlayer.isMuted = !soundEnabled
        videoPlayer.volume = 0.86
        videoPlayer.actionAtItemEnd = .pause
        videoPlayer.automaticallyWaitsToMinimizeStalling = false
        player = videoPlayer

        let presentation = AVPlayerLayer(player: videoPlayer)
        presentation.frame = bounds
        presentation.videoGravity = .resizeAspectFill
        layer.addSublayer(presentation)
        playerLayer = presentation

        // All typography is an overlay: the master remains colour-accurate
        // and is never composited with a bloom or tinted bitmap.
        buildSignature()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.finish()
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.finish()
        }
        itemStatus = item.observe(\.status, options: [.new]) {
            [weak self] item, _ in
            if item.status == .failed {
                DispatchQueue.main.async { [weak self] in
                    self?.finish()
                }
            }
        }

        playbackClock = videoPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.finished else { return }
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                self.update(at: seconds)
            }
        }
    }

    private func start() {
        guard !started, let player else { return }
        started = true

        // Ambient keeps user music playing and respects the hardware silent
        // switch. In-app mute and the physical mute control both apply.
        try? AVAudioSession.sharedInstance().setCategory(
            .ambient, mode: .default, options: [.mixWithOthers]
        )
        player.playImmediately(atRate: 1)

        // Avoid holding the launch gate if video decoding stalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            self?.finish()
        }
    }

    private func buildSignature() {
        let tokens = ["Sideloading", "and", "beyond."]
        let size = min(23, max(16, bounds.width * 0.054))
        let weights: [UIFont.Weight] = [.light, .ultraLight, .semibold]
        let tracking: [CGFloat] = [1.1, 0.9, 0.35]
        let gap = size * 0.49
        let widths = tokens.enumerated().map { i, word -> CGFloat in
            let font = UIFont.systemFont(ofSize: size, weight: weights[i])
            let measured = (word as NSString).size(
                withAttributes: [.font: font]
            ).width
            return ceil(measured + CGFloat(word.count - 1) * tracking[i])
        }
        let idealWidth = widths.reduce(0, +) + gap * 2
        let fit = min(1, (bounds.width - 38) / idealWidth)
        let totalWidth = idealWidth * fit
        let y = bounds.height * 0.690
        var x = (bounds.width - totalWidth) / 2
        sweepRange = CGRect(
            x: x - 7, y: y + size * fit * 1.28,
            width: totalWidth + 14, height: 2
        )

        for (index, token) in tokens.enumerated() {
            let width = widths[index] * fit
            let font = UIFont.systemFont(
                ofSize: size * fit, weight: weights[index]
            )
            let style: [NSAttributedString.Key: Any] = [
                .font: font,
                .kern: tracking[index] * fit,
                .foregroundColor: UIColor.white.withAlphaComponent(
                    index == 1 ? 0.72 : 0.98
                )
            ]
            let text = CATextLayer()
            text.frame = CGRect(
                x: x, y: y,
                width: width + 2, height: size * fit * 1.8
            )
            text.contentsScale = UIScreen.main.scale
            text.alignmentMode = .center
            text.isWrapped = false
            text.truncationMode = .none
            text.string = NSAttributedString(
                string: token, attributes: style
            )
            text.opacity = 0
            layer.addSublayer(text)
            wordLayers.append(text)

            // Glint is *only* visible through these exact glyph shapes.
            let glyph = CATextLayer()
            glyph.frame = text.bounds
            glyph.contentsScale = UIScreen.main.scale
            glyph.alignmentMode = .center
            glyph.string = text.string

            let sleeve = CALayer()
            sleeve.frame = text.frame
            sleeve.mask = glyph
            layer.addSublayer(sleeve)

            let glint = CAGradientLayer()
            glint.frame = CGRect(
                x: -width * 0.75, y: 0,
                width: width * 0.48, height: sleeve.bounds.height
            )
            glint.colors = [
                UIColor.clear.cgColor,
                UIColor.white.withAlphaComponent(0.08).cgColor,
                UIColor.white.withAlphaComponent(0.52).cgColor,
                UIColor.clear.cgColor
            ]
            glint.locations = [0, 0.32, 0.57, 1]
            glint.startPoint = CGPoint(x: 0, y: 0)
            glint.endPoint = CGPoint(x: 1, y: 0.22)
            glint.opacity = 0
            sleeve.addSublayer(glint)
            wordGlints.append(glint)

            x += width + gap * fit
        }

        // A hairline moves with the text revelation, mirroring the spirit of
        // the white Z tracer without visually competing with the main mark.
        let beam = CAGradientLayer()
        beam.frame = CGRect(
            x: sweepRange.minX - 25, y: sweepRange.minY,
            width: 44, height: 1
        )
        beam.colors = [
            UIColor.clear.cgColor,
            UIColor.white.withAlphaComponent(0.15).cgColor,
            UIColor.white.withAlphaComponent(0.90).cgColor,
            UIColor.clear.cgColor
        ]
        beam.locations = [0, 0.32, 0.63, 1]
        beam.opacity = 0
        layer.addSublayer(beam)
        sweep = beam
    }

    private func update(at seconds: Double) {
        if !startedSweep && seconds >= arrivalTimes[0] - 0.08 {
            startedSweep = true
            animateSweep()
        }

        for index in 0..<revealed.count
            where !revealed[index] && seconds >= arrivalTimes[index] {
            revealed[index] = true
            revealWord(at: index)
        }

        // Final audio tail is gently tapered, never cut off mid-note.
        if let player {
            let remaining = max(0, videoDuration - seconds)
            let gain = min(1, remaining / 0.44)
            player.volume = Float(0.86 * gain)
        }
    }

    private func revealWord(at index: Int) {
        let text = wordLayers[index]
        let duration: CFTimeInterval = index == 2 ? 0.68 : 0.60
        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.opacity = 1

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration * 0.88
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let lift = CABasicAnimation(keyPath: "position.y")
        lift.fromValue = text.position.y + (index == 2 ? 6 : 4)
        lift.toValue = text.position.y
        lift.duration = duration
        lift.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.14, 0.67, 0.23, 1
        )

        let focus = CABasicAnimation(keyPath: "transform.scale.x")
        focus.fromValue = index == 2 ? 1.09 : 1.045
        focus.toValue = 1
        focus.duration = duration
        focus.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [fade, lift, focus]
        group.beginTime = now
        group.duration = duration
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        text.add(group, forKey: "zag.signatureReveal")

        let glint = wordGlints[index]
        glint.position.x = text.bounds.width + glint.bounds.width
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = -glint.bounds.width
        travel.toValue = glint.position.x
        travel.duration = duration * 0.95
        travel.beginTime = now + 0.10
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        travel.fillMode = .both
        travel.isRemovedOnCompletion = false
        glint.add(travel, forKey: "zag.signatureLightTravel")

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0.54, 0.36, 0]
        flash.keyTimes = [0, 0.22, 0.72, 1]
        flash.beginTime = now + 0.10
        flash.duration = duration * 0.95
        flash.fillMode = .both
        flash.isRemovedOnCompletion = false
        glint.add(flash, forKey: "zag.signatureCatch")

        CATransaction.commit()
    }

    private func animateSweep() {
        guard let beam = sweep else { return }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        beam.position.x = sweepRange.maxX
        let movement = CABasicAnimation(keyPath: "position.x")
        movement.fromValue = sweepRange.minX
        movement.toValue = sweepRange.maxX
        movement.duration = 1.57
        movement.beginTime = now
        movement.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.24, 0.08, 0.24, 1
        )
        movement.fillMode = .both
        movement.isRemovedOnCompletion = false
        beam.add(movement, forKey: "zag.signatureTrace")

        let luminance = CAKeyframeAnimation(keyPath: "opacity")
        luminance.values = [0, 0.55, 0.42, 0]
        luminance.keyTimes = [0, 0.12, 0.80, 1]
        luminance.beginTime = now
        luminance.duration = 1.57
        luminance.fillMode = .both
        luminance.isRemovedOnCompletion = false
        beam.add(luminance, forKey: "zag.signatureTraceLight")
        CATransaction.commit()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        player?.pause()
        onFinished?()
    }

    deinit {
        if let playbackClock, let player {
            player.removeTimeObserver(playbackClock)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        itemStatus?.invalidate()
        player?.pause()
    }
}

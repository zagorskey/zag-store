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
    let skipRequested: Bool
    let onExitReady: () -> Void
    let onFinished: () -> Void

    func makeUIView(context: Context) -> ZagCinematicSplashStage {
        let view = ZagCinematicSplashStage()
        view.onFinished = onFinished
        view.onExitReady = onExitReady
        view.soundEnabled = soundEnabled
        if skipRequested { view.requestSkip() }
        return view
    }

    func updateUIView(_ uiView: ZagCinematicSplashStage, context: Context) {
        uiView.onFinished = onFinished
        uiView.onExitReady = onExitReady
        uiView.soundEnabled = soundEnabled
        if skipRequested { uiView.requestSkip() }
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
    var onExitReady: (() -> Void)?
    var soundEnabled: Bool = true {
        didSet {
            player?.isMuted = !soundEnabled
        }
    }

    // Pixel-identical frame zero of the bundled master, also used by the
    // iOS launch storyboard. Avoid colour overlays, alpha dimming or gradients.
    private let backgroundImage = UIImageView(image: UIImage(named: "ZagSplashVideoFirstFrame"))
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playbackClock: Any?
    private var endObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var itemStatus: NSKeyValueObservation?
    private var started = false
    private var finished = false
    private var exitSent = false
    private var outroStarted = false
    private var skipStarted = false
    private var prepared = false
    private var wordLayers: [CATextLayer] = []
    private var wordGlints: [CAGradientLayer] = []
    private var revealed = [false, false, false]
    private var sweep: CAGradientLayer?
    private var sweepRange = CGRect.zero
    private var startedSweep = false

    // Timed against the PLAYER rather than wall-clock time. Buffering or
    // device startup delay never separates the motto from its video cue.
    // Master measurements: the glass resolves at ~2.15s, and the largest
    // musical accent is at 1.95–2.15s. The final word arrives as the halo
    // settles, then has a full second of undisturbed screen time.
    private let arrivalTimes: [Double] = [2.18, 2.76, 3.26]
    private let outroStart: Double = 4.34
    private let crossfadeStart: Double = 4.76
    private let videoDuration: Double = 5.041667

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 3/255, green: 5/255, blue: 15/255, alpha: 1)
        clipsToBounds = true
        backgroundImage.contentMode = .scaleAspectFill
        backgroundImage.clipsToBounds = true
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
        guard !skipStarted else { return }
        if !startedSweep && seconds >= arrivalTimes[0] - 0.08 {
            startedSweep = true
            animateSweep()
        }

        for index in 0..<revealed.count
            where !revealed[index] && seconds >= arrivalTimes[index] {
            revealed[index] = true
            revealWord(at: index)
        }

        // The words depart first; only then does the Z dissolve into the
        // already-rendered app. Neither gesture nor letter layers tint the
        // original video pixels.
        if !outroStarted && seconds >= outroStart {
            outroStarted = true
            animateSignatureOutro()
        }
        if !exitSent && seconds >= crossfadeStart {
            exitSent = true
            onExitReady?()
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

    private func animateSignatureOutro() {
        let now = CACurrentMediaTime()

        for (index, text) in wordLayers.enumerated() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let from = text.presentation()?.opacity ?? text.opacity
            text.opacity = 0

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = 0
            fade.beginTime = now + Double(index) * 0.075
            fade.duration = index == 2 ? 0.34 : 0.27
            fade.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.42, 0, 0.74, 0.39
            )
            text.add(fade, forKey: "zag.signatureOutro")

            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = text.position.y
            rise.toValue = text.position.y - 3.0
            rise.beginTime = fade.beginTime
            rise.duration = fade.duration
            rise.timingFunction = CAMediaTimingFunction(name: .easeIn)
            text.add(rise, forKey: "zag.signatureOutroLift")
            CATransaction.commit()
        }

        if let beam = sweep {
            beam.removeAllAnimations()
            beam.opacity = 0
        }
        for glint in wordGlints {
            glint.removeAllAnimations()
            glint.opacity = 0
        }
    }

    /// Exit is also used by the preview and the invisible tap-to-skip
    /// gesture. We fade the actual soundtrack rather than just muting it.
    func requestSkip() {
        guard !finished, !skipStarted else { return }
        skipStarted = true
        if !exitSent {
            exitSent = true
            onExitReady?()
        }
        let initialVolume = player?.volume ?? 0
        for step in 1...10 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(step) * 0.031
            ) { [weak self] in
                guard let self, !self.finished else { return }
                self.player?.volume = initialVolume * Float(10-step) / 10
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        player?.pause()
        // Even an AVPlayerItem failure or watchdog release performs a graceful
        // outro; SwiftUI closes after the fade has had time to complete.
        if !exitSent {
            exitSent = true
            onExitReady?()
        }
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


// MARK: - Full-screen replay from Settings
//
// Entirely separate from ZagLaunchGate: previewing must never reset,
// wait for, or mark the cold-launch gate interactive. The player is created
// fresh on every presentation, and its soundtrack honours the same toggle.
struct ZagCinematicSplashPreview: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ZagStore.splashSoundEnabled") private var soundEnabled = true
    @State private var opacity: Double = 1
    @State private var skipRequested = false
    @State private var exitStarted = false
    @State private var closing = false

    var body: some View {
        ZStack {
            Color(red: 3 / 255, green: 5 / 255, blue: 15 / 255)

            ZagCinematicSplashView(
                soundEnabled: soundEnabled,
                skipRequested: skipRequested,
                onExitReady: beginOutro,
                onFinished: completeOutro
            )
        }
        .ignoresSafeArea()
        .opacity(opacity)
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { skipRequested = true }
                .accessibilityLabel("Skip splash preview")
                .accessibilityHint("Double tap to close the cinematic introduction")
                .accessibilityAddTraits(.isButton)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Transparent modal backing is essential: as the film dissolves, the
        // Settings page underneath is already visible instead of a black
        // presentation surface suddenly cutting back to the app.
        .presentationBackground(.clear)
        .interactiveDismissDisabled()
    }

    private func beginOutro() {
        guard !exitStarted else { return }
        exitStarted = true
        withAnimation(.easeInOut(duration: 0.28)) {
            opacity = 0
        }
    }

    private func completeOutro() {
        guard !closing else { return }
        closing = true
        let alreadyFading = exitStarted
        beginOutro()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(
                alreadyFading ? 55 : 310
            ))
            dismiss()
        }
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

// The morphing install control, drawn with Core Animation.
//
// Three concerns stay independent:
// - Installation state: the row passes a ZagInstallControlMode.
// - Morph: the capsule's size, corner radius and the label/ring fades are
//   keyframe animations sampled from ZagInstallControlFrame. They're
//   committed once per state change and then run in the render server, so a
//   busy main thread can neither freeze nor skip them.
// - Ring: the spinner is a repeating rotation and progress is strokeEnd,
//   both on their own layers. Progress ticks only touch strokeEnd; a morph
//   never restarts the spinner, and the spinner's phase follows the clock.
//
// Geometry is unchanged: a fixed 88 × 34 slot, the shape centred in it.

struct ZagInstallControlBody: View {
	let mode: ZagInstallControlMode
	let tint: Color
	let fill: Color
	let action: () -> Void

	/// Hit area width: the widest the visible shape is during the current
	/// morph, settling on the target once the morph is over.
	@State private var hitWidth: Double
	@State private var pressed = false

	init(mode: ZagInstallControlMode, tint: Color, fill: Color, action: @escaping () -> Void) {
		self.mode = mode
		self.tint = tint
		self.fill = fill
		self.action = action
		_hitWidth = State(initialValue: Self.targetHitWidth(mode))
	}

	private static func targetHitWidth(_ mode: ZagInstallControlMode) -> Double {
		ZagInstallControlLayout.hitWidth(
			compact: mode.isCompact,
			pillWidth: mode.pill.map(ZagInstallControlMeasure.pillWidth) ?? ZagInstallControlLayout.slotWidth
		)
	}

	var body: some View {
		let target = Self.targetHitWidth(mode)
		// The Core Animation view only draws. Taps are claimed by a SwiftUI
		// Button, so SwiftUI's own arbitration gives them to the control
		// exclusively; a row's tap gesture or Button never sees them.
		ZagInstallControlRepresentable(mode: mode, tint: tint, fill: fill)
			.frame(width: ZagInstallControlLayout.slotWidth, height: ZagInstallControlLayout.pillHeight)
			.opacity(pressed && mode.isInteractive ? 0.45 : 1)
			.overlay {
				Button {
					if mode.isInteractive { action() }
				} label: {
					// Centred on the slot; a wider pill (Resume) extends
					// equally on both sides, like the visible shape.
					Color.clear
						.frame(width: hitWidth, height: ZagInstallControlLayout.pillHeight)
						.contentShape(Capsule(style: .continuous))
				}
				.buttonStyle(ZagInstallControlPressStyle(pressed: $pressed))
				.accessibilityHidden(true)
			}
			.task(id: target) {
				// Cover both the old and the new shape while the morph runs.
				hitWidth = max(hitWidth, target)
				try? await Task.sleep(nanoseconds: UInt64((ZagInstallControlMotion.springDuration + 0.05) * 1_000_000_000))
				if !Task.isCancelled { hitWidth = target }
			}
	}
}

/// Reports the pressed state so the drawn control can dim, like a button.
private struct ZagInstallControlPressStyle: ButtonStyle {
	@Binding var pressed: Bool

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.onChange(of: configuration.isPressed) { pressed = $0 }
	}
}

private struct ZagInstallControlRepresentable: UIViewRepresentable {
	let mode: ZagInstallControlMode
	let tint: Color
	let fill: Color

	func makeUIView(context: Context) -> ZagInstallControlView {
		ZagInstallControlView()
	}

	func updateUIView(_ view: ZagInstallControlView, context: Context) {
		view.update(
			mode: mode,
			tint: UIColor(tint),
			fill: UIColor(fill),
			reduceMotion: context.environment.accessibilityReduceMotion
		)
	}
}

/// Draws the control. It never handles touches.
final class ZagInstallControlView: UIView {
	private let capsule = CALayer()
	private let labelHost = UIView()
	private let iconView = UIImageView()
	private let titleLabel = UILabel()
	private let ringView = UIView()
	private let track = CAShapeLayer()
	private let progressArc = CAShapeLayer()
	private let spinnerArc = CAShapeLayer()
	private let glyphView = UIImageView()

	private var mode: ZagInstallControlMode?
	private var pill = ZagInstallPill(title: nil, accessibilityLabel: "")
	private var ring: ZagInstallRing = .spinner(.none)
	private var contentWidth = 0.0
	private var reduceMotion = false
	private var tint: UIColor = .systemBlue
	private var fillColor: UIColor = .systemGray5

	/// Target of the current or last morph, and when it started.
	private var compactness = 0.0
	private var pillWidth = ZagInstallControlLayout.slotWidth
	private var morph: (start: CFTimeInterval, c0: Double, w0: Double, reduce: Bool)?

	private static let spinKey = "zag.spin"
	private static let morphKey = "zag.morph"
	private static let spinPeriod = 0.85

	override init(frame: CGRect) {
		super.init(frame: frame)
		clipsToBounds = false
		backgroundColor = .clear

		capsule.cornerCurve = .continuous
		layer.addSublayer(capsule)

		titleLabel.font = .systemFont(ofSize: ZagInstallControlLayout.titleSize, weight: .bold)
		titleLabel.numberOfLines = 1
		iconView.contentMode = .center
		labelHost.isUserInteractionEnabled = false
		labelHost.addSubview(iconView)
		labelHost.addSubview(titleLabel)
		addSubview(labelHost)

		let size = ZagInstallControlLayout.circle
		ringView.isUserInteractionEnabled = false
		ringView.bounds = CGRect(x: 0, y: 0, width: size, height: size)
		let circle = UIBezierPath(
			arcCenter: CGPoint(x: size / 2, y: size / 2), radius: size / 2,
			startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
		).cgPath
		for arc in [track, progressArc, spinnerArc] {
			arc.frame = ringView.bounds
			arc.path = circle
			arc.fillColor = nil
			arc.lineWidth = ZagInstallControlLayout.ringStroke
			arc.lineCap = .round
			ringView.layer.addSublayer(arc)
		}
		progressArc.strokeEnd = 0
		spinnerArc.strokeStart = 0.08
		spinnerArc.strokeEnd = 0.72
		glyphView.contentMode = .center
		glyphView.frame = ringView.bounds
		ringView.addSubview(glyphView)
		addSubview(ringView)

		isUserInteractionEnabled = false
		NotificationCenter.default.addObserver(
			self, selector: #selector(_restoreSpin),
			name: UIApplication.willEnterForegroundNotification, object: nil
		)
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

	override var intrinsicContentSize: CGSize {
		CGSize(width: ZagInstallControlLayout.slotWidth, height: ZagInstallControlLayout.pillHeight)
	}

	// MARK: Layout

	override func layoutSubviews() {
		super.layoutSubviews()
		let centre = CGPoint(x: bounds.midX, y: bounds.midY)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		capsule.position = centre
		CATransaction.commit()
		ringView.center = centre
		labelHost.center = centre
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		guard window != nil else { return }
		_restoreSpin()
		// Animations are dropped when a layer leaves the window; settle on
		// the target instead of leaving a half-finished frame.
		if capsule.animation(forKey: Self.morphKey) == nil { _applyStatic() }
	}

	// MARK: Update

	func update(mode newMode: ZagInstallControlMode, tint newTint: UIColor, fill newFill: UIColor, reduceMotion newReduce: Bool) {
		reduceMotion = newReduce
		if newTint != tint || newFill != fillColor || mode == nil {
			tint = newTint
			fillColor = newFill
			_applyColours()
		}
		if let p = newMode.pill, p != pill || mode == nil { _setPill(p) }
		if let r = newMode.ring { _setRing(r, animated: mode != nil) }

		let targetC: Double = newMode.isCompact ? 1 : 0
		let targetW = newMode.pill.map(ZagInstallControlMeasure.pillWidth) ?? pillWidth
		if mode == nil {
			// First appearance (including scrolling back on-screen): no morph.
			compactness = targetC
			pillWidth = targetW
			_applyStatic()
		} else if targetC != compactness || targetW != pillWidth {
			_morph(toCompactness: targetC, width: targetW)
		}
		mode = newMode
		accessibilityElementsHidden = true
	}

	private func _applyColours() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		capsule.backgroundColor = fillColor.cgColor
		titleLabel.textColor = tint
		iconView.tintColor = tint
		glyphView.tintColor = tint
		track.strokeColor = tint.withAlphaComponent(0.22).cgColor
		progressArc.strokeColor = tint.cgColor
		spinnerArc.strokeColor = tint.cgColor
		CATransaction.commit()
	}

	private func _setPill(_ p: ZagInstallPill) {
		pill = p
		contentWidth = ZagInstallControlMeasure.contentWidth(p)
		let font = p.labelFont
		let weight = ZagInstallControlMeasure.weight(font)
		titleLabel.font = .systemFont(ofSize: font.size, weight: weight)
		titleLabel.text = p.title
		titleLabel.isHidden = p.title == nil
		if let name = p.systemImage {
			let config = p.title == nil
				? UIImage.SymbolConfiguration(pointSize: p.iconSize, weight: .regular)
				: UIImage.SymbolConfiguration(pointSize: font.size, weight: ZagInstallControlMeasure.symbolWeight(font))
			iconView.image = UIImage(systemName: name, withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
			iconView.isHidden = false
		} else {
			iconView.image = nil
			iconView.isHidden = true
		}
		// Lay the label out at its natural size, centred: never truncated.
		let titleSize = p.title == nil ? .zero : titleLabel.sizeThatFits(CGSize(width: 1000, height: 100))
		let iconSize = iconView.image?.size ?? .zero
		let spacing = (p.title != nil && p.systemImage != nil) ? font.iconSpacing : 0
		let width = iconSize.width + spacing + titleSize.width
		let height = max(iconSize.height, titleSize.height, ZagInstallControlLayout.pillHeight)
		labelHost.bounds = CGRect(x: 0, y: 0, width: width, height: height)
		var titleFrame = CGRect(x: iconSize.width + spacing, y: (height - titleSize.height) / 2, width: titleSize.width, height: titleSize.height)
		var iconFrame = CGRect(x: 0, y: (height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
		if p.title != nil, let offset = iconView.image?.baselineOffsetFromBottom {
			// Sit the symbol on the title's baseline, then centre the pair
			// optically: midway between the symbol's centre and the
			// title's cap-height centre lands on the pill's centre, as in
			// App Store's Resume.
			let baseline = titleFrame.minY + titleLabel.font.ascender
			iconFrame.origin.y = baseline - (iconSize.height - offset)
			let capCentre = baseline - titleLabel.font.capHeight / 2
			let shift = height / 2 - (iconFrame.midY + capCentre) / 2
			iconFrame.origin.y += shift
			titleFrame.origin.y += shift
		}
		iconView.frame = iconFrame
		titleLabel.frame = titleFrame
		labelHost.center = CGPoint(x: bounds.midX, y: bounds.midY)
	}

	// MARK: Ring

	private func _setRing(_ r: ZagInstallRing, animated: Bool) {
		let previous = ring
		ring = r
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		switch r {
		case .progress(let value, _):
			spinnerArc.isHidden = true
			spinnerArc.removeAnimation(forKey: Self.spinKey)
			progressArc.isHidden = false
			let target = CGFloat(max(0.03, min(1, value)))
			let wasProgress: Bool = { if case .progress = previous { return true } else { return false } }()
			if animated, wasProgress, abs(progressArc.strokeEnd - target) > 0.0005 {
				// Continue from what is on screen, so frequent ticks glide.
				let from = progressArc.presentation()?.strokeEnd ?? progressArc.strokeEnd
				let glide = CABasicAnimation(keyPath: "strokeEnd")
				glide.fromValue = from
				glide.toValue = target
				glide.duration = 0.5
				glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
				progressArc.add(glide, forKey: "zag.progress")
			}
			progressArc.strokeEnd = target
		case .spinner:
			progressArc.isHidden = true
			progressArc.removeAnimation(forKey: "zag.progress")
			spinnerArc.isHidden = false
			_ensureSpin()
		}
		CATransaction.commit()
		_setGlyph(for: r)
	}

	private func _setGlyph(for r: ZagInstallRing) {
		let footnote = UIImage.SymbolConfiguration(textStyle: .footnote)
		let image: UIImage?
		switch (r, r.glyph) {
		case (_, .pause): image = UIImage(systemName: "pause.fill", withConfiguration: footnote)
		case (_, .stop): image = UIImage(systemName: "square.fill", withConfiguration: footnote)
		case (.progress(let v, _), .none) where v >= 1:
			image = UIImage(systemName: "checkmark", withConfiguration: footnote.applying(UIImage.SymbolConfiguration(weight: .bold)))
		default: image = nil
		}
		glyphView.image = image?.withRenderingMode(.alwaysTemplate)
	}

	/// The spinner rotates in the render server. Its phase follows the
	/// clock, so re-adding it (scrolling back, returning to the app) never
	/// visibly restarts it.
	@objc private func _restoreSpin() {
		guard case .spinner = ring else { return }
		_ensureSpin()
	}

	private func _ensureSpin() {
		guard spinnerArc.animation(forKey: Self.spinKey) == nil else { return }
		let spin = CABasicAnimation(keyPath: "transform.rotation.z")
		spin.fromValue = 0
		spin.toValue = 2 * Double.pi
		spin.duration = Self.spinPeriod
		spin.repeatCount = .infinity
		spin.isRemovedOnCompletion = false
		spin.timeOffset = fmod(CACurrentMediaTime(), Self.spinPeriod)
		spinnerArc.add(spin, forKey: Self.spinKey)
	}

	// MARK: Morph

	private func _currentFrame() -> ZagInstallControlFrame {
		.at(compactness: compactness, pillWidth: pillWidth, contentWidth: contentWidth, filled: pill.filled, reduceMotion: reduceMotion)
	}

	private func _applyStatic() {
		capsule.removeAnimation(forKey: Self.morphKey)
		labelHost.layer.removeAnimation(forKey: Self.morphKey)
		ringView.layer.removeAnimation(forKey: Self.morphKey)
		morph = nil
		_set(_currentFrame())
	}

	private func _set(_ f: ZagInstallControlFrame) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		capsule.bounds = CGRect(x: 0, y: 0, width: f.width, height: f.height)
		capsule.cornerRadius = f.cornerRadius
		capsule.opacity = Float(f.fillOpacity)
		labelHost.layer.opacity = Float(f.labelOpacity)
		ringView.layer.opacity = Float(f.ringOpacity)
		CATransaction.commit()
	}

	private func _morph(toCompactness c1: Double, width w1: Double) {
		// Start from where the shape is now, including mid-morph.
		var c0 = compactness, w0 = pillWidth
		if let morph, capsule.animation(forKey: Self.morphKey) != nil {
			let p = ZagInstallControlMotion.progress(elapsed: CACurrentMediaTime() - morph.start, reduceMotion: morph.reduce)
			c0 = morph.c0 + (compactness - morph.c0) * p
			w0 = morph.w0 + (pillWidth - morph.w0) * p
		}
		if reduceMotion { w0 = w1 }
		compactness = c1
		pillWidth = w1

		let keys = ZagInstallControlMotion.keyframes(
			fromCompactness: c0, toCompactness: c1, fromWidth: w0, toWidth: w1,
			contentWidth: contentWidth, filled: pill.filled, reduceMotion: reduceMotion
		)
		let times = keys.frames.indices.map { NSNumber(value: Double($0) / Double(keys.frames.count - 1)) }
		func animation(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
			let a = CAKeyframeAnimation(keyPath: path)
			a.values = values
			a.keyTimes = times
			a.duration = keys.duration
			a.calculationMode = .linear
			return a
		}
		let start = CACurrentMediaTime()
		morph = (start, c0, w0, reduceMotion)

		// Final values first, then the animations from the same transaction.
		_set(keys.frames.last!)
		let shape = CAAnimationGroup()
		shape.animations = [
			animation("bounds.size", keys.frames.map { NSValue(cgSize: CGSize(width: $0.width, height: $0.height)) }),
			animation("cornerRadius", keys.frames.map { $0.cornerRadius }),
			animation("opacity", keys.frames.map { $0.fillOpacity }),
		]
		shape.duration = keys.duration
		capsule.add(shape, forKey: Self.morphKey)
		labelHost.layer.add(animation("opacity", keys.frames.map { $0.labelOpacity }), forKey: Self.morphKey)
		ringView.layer.add(animation("opacity", keys.frames.map { $0.ringOpacity }), forKey: Self.morphKey)
	}
}
#endif

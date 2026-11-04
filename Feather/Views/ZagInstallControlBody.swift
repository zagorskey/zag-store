import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The morphing install control without any app dependencies, so the same
// code runs in the app and in the visual test harness.
//
// One persistent view in a fixed 88 × 34 slot. Two animated values drive
// everything, through ZagInstallControlFrame:
//   compactness 0 (pill) … 1 (circle), and the target pill width.
// Both change in one spring transaction, only when the control moves
// between pill and circle or between two different pills. Progress ticks
// update the ring without touching the morph.

struct ZagInstallControlBody: View {
	let mode: ZagInstallControlMode
	let tint: Color
	let fill: Color
	let action: () -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	@State private var compactness: Double
	@State private var pillWidth: Double
	/// The last pill and ring shown, so contents stay put while they fade.
	@State private var shownPill: ZagInstallPill
	@State private var shownRing: ZagInstallRing

	init(mode: ZagInstallControlMode, tint: Color, fill: Color, action: @escaping () -> Void) {
		self.mode = mode
		self.tint = tint
		self.fill = fill
		self.action = action
		let pill = mode.pill ?? ZagInstallPill(title: nil, accessibilityLabel: "")
		_compactness = State(initialValue: mode.isCompact ? 1 : 0)
		_pillWidth = State(initialValue: ZagInstallControlMeasure.pillWidth(pill))
		_shownPill = State(initialValue: pill)
		_shownRing = State(initialValue: mode.ring ?? .spinner(.none))
	}

	var body: some View {
		let pill = mode.pill ?? shownPill
		Button {
			if mode.isInteractive { action() }
		} label: {
			ZagInstallControlFace(
				compactness: compactness,
				pillWidth: pillWidth,
				contentWidth: ZagInstallControlMeasure.contentWidth(pill),
				pill: pill,
				ring: mode.ring ?? shownRing,
				tint: tint,
				fill: fill,
				reduceMotion: reduceMotion
			)
		}
		.buttonStyle(.borderless)
		.allowsHitTesting(mode.isInteractive)
		// Fixed slot, centred: the shape grows and shrinks around the slot's
		// centre and the row never reflows. A wider pill (Resume) extends
		// equally on both sides.
		.frame(width: ZagInstallControlLayout.slotWidth, height: ZagInstallControlLayout.pillHeight)
		.onChange(of: mode) { newMode in
			_apply(newMode)
		}
	}

	private func _apply(_ newMode: ZagInstallControlMode) {
		// Contents first, outside the animation.
		if let pill = newMode.pill { shownPill = pill }
		if let ring = newMode.ring { shownRing = ring }

		let targetCompactness: Double = newMode.isCompact ? 1 : 0
		let targetWidth = newMode.pill.map(ZagInstallControlMeasure.pillWidth) ?? pillWidth
		guard targetCompactness != compactness || targetWidth != pillWidth else { return }
		// Reduce Motion: the width is set at once and only the contents
		// cross-fade, so nothing resizes in motion.
		if reduceMotion { pillWidth = targetWidth }
		let animation: Animation = reduceMotion
			? .easeInOut(duration: ZagInstallControlMotion.reduceMotionDuration)
			: .spring(response: ZagInstallControlMotion.response, dampingFraction: ZagInstallControlMotion.dampingFraction)
		withAnimation(animation) {
			compactness = targetCompactness
			pillWidth = targetWidth
		}
	}
}

/// One rendered frame of the morph. SwiftUI interpolates `animatableData`,
/// so every size and opacity is recomputed from the same spring each frame.
struct ZagInstallControlFace: View, Animatable {
	var compactness: Double
	var pillWidth: Double
	let contentWidth: Double
	let pill: ZagInstallPill
	let ring: ZagInstallRing
	let tint: Color
	let fill: Color
	var reduceMotion = false

	var animatableData: AnimatablePair<Double, Double> {
		get { AnimatablePair(compactness, pillWidth) }
		set {
			compactness = newValue.first
			pillWidth = newValue.second
		}
	}

	var body: some View {
		let frame = ZagInstallControlFrame.at(
			compactness: compactness,
			pillWidth: pillWidth,
			contentWidth: contentWidth,
			filled: pill.filled,
			reduceMotion: reduceMotion
		)
		// The shape alone sets the size. Label and ring are overlays centred
		// on it, so a wider label can never widen or shift the capsule.
		Color.clear
			.frame(width: frame.width, height: frame.height)
			.background(
				Capsule(style: .continuous)
					.fill(fill)
					.opacity(frame.fillOpacity)
			)
			.overlay(
				_label
					.opacity(frame.labelOpacity)
			)
			.overlay(
				ZagInstallRingView(ring: ring, tint: tint, paused: reduceMotion)
					.frame(width: ZagInstallControlLayout.circle, height: ZagInstallControlLayout.circle)
					.opacity(frame.ringOpacity)
			)
			.contentShape(Capsule(style: .continuous))
	}

	private var _label: some View {
		HStack(spacing: ZagInstallControlLayout.iconSpacing) {
			if let image = pill.systemImage {
				Image(systemName: image)
					.font(pill.title == nil
						? .system(size: pill.iconSize, weight: .regular)
						: .system(size: ZagInstallControlLayout.titleSize, weight: .bold))
			}
			if let title = pill.title {
				Text(title)
					.font(.system(size: ZagInstallControlLayout.titleSize, weight: .bold))
					.lineLimit(1)
			}
		}
		.foregroundStyle(tint)
		// Natural size: never truncated, compressed or clipped. It fades
		// out before the capsule edge reaches it.
		.fixedSize()
	}
}

struct ZagInstallRingView: View {
	let ring: ZagInstallRing
	let tint: Color
	var paused = false

	var body: some View {
		ZStack {
			Circle()
				.stroke(tint.opacity(0.22), lineWidth: ZagInstallControlLayout.ringStroke)
			switch ring {
			case .progress(let value, let glyph):
				Circle()
					.trim(from: 0, to: max(0.03, min(1, value)))
					.stroke(tint, style: StrokeStyle(lineWidth: ZagInstallControlLayout.ringStroke, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.animation(.smooth, value: value)
				if glyph == .none, value >= 1 {
					Image(systemName: "checkmark")
						.font(.footnote.bold())
						.foregroundStyle(tint)
				}
			case .spinner:
				// Driven by the clock, so it never restarts when the row
				// scrolls off-screen and back.
				TimelineView(.animation(paused: paused)) { context in
					let period = 0.85
					let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
					Circle()
						.trim(from: 0.08, to: 0.72)
						.stroke(tint, style: StrokeStyle(lineWidth: ZagInstallControlLayout.ringStroke, lineCap: .round))
						.rotationEffect(.degrees(turn * 360 - 90))
				}
			}
			switch ring.glyph {
			case .pause:
				Image(systemName: "pause.fill").font(.footnote).foregroundStyle(tint)
			case .stop:
				Image(systemName: "square.fill").font(.footnote).foregroundStyle(tint)
			case .none:
				EmptyView()
			}
		}
	}
}

/// Measures labels with the same fonts the face renders, so the pill width
/// is known before the morph starts.
enum ZagInstallControlMeasure {
	static func pillWidth(_ pill: ZagInstallPill) -> Double {
		ZagInstallControlLayout.pillWidth(contentWidth: contentWidth(pill))
	}

	static func contentWidth(_ pill: ZagInstallPill) -> Double {
		let size = pill.title == nil ? pill.iconSize : ZagInstallControlLayout.titleSize
		let symbol = pill.systemImage.map { symbolWidth($0, pointSize: size, bold: pill.title != nil) }
		let title = pill.title.map(titleWidth)
		return ZagInstallControlLayout.contentWidth(titleWidth: title, symbolWidth: symbol)
	}

	static func titleWidth(_ title: String) -> Double {
		#if canImport(UIKit)
		let font = UIFont.systemFont(ofSize: ZagInstallControlLayout.titleSize, weight: .bold)
		#else
		let font = NSFont.systemFont(ofSize: ZagInstallControlLayout.titleSize, weight: .bold)
		#endif
		return Double((title as NSString).size(withAttributes: [.font: font]).width).rounded(.up)
	}

	static func symbolWidth(_ name: String, pointSize: Double, bold: Bool) -> Double {
		#if canImport(UIKit)
		let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: bold ? .bold : .regular)
		return (UIImage(systemName: name, withConfiguration: config).map { Double($0.size.width) } ?? pointSize).rounded(.up)
		#else
		let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: bold ? .bold : .regular)
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
		return (image.map { Double($0.size.width) } ?? pointSize).rounded(.up)
		#endif
	}
}

import SwiftUI

/// One continuous App Store-style install control. The row always shows
/// this view in the same place and only changes its `mode`, so Get →
/// progress → Open is one element morphing, never a view swap.
///
/// Geometry and timing come from ZagInstallControlModel. The pill keeps
/// ZagActionPill's size, capsule, fill, tint and 17 pt bold label; the
/// circle keeps the existing 31 pt ring with a 2.3 pt stroke.
struct ZagInstallControl: View {
	let mode: ZagInstallControlMode
	var tint: Color? = nil
	var fill: Color? = nil
	let action: () -> Void
	/// Exposed to VoiceOver as a custom action when cancellation is possible.
	var cancelAction: (() -> Void)? = nil

	@AppStorage("Feather.userTintColor") private var tintHex: String = "#3F8EF7"
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private var resolvedTint: Color { tint ?? ZagWideGamutTint.color(hex: tintHex) }
	private var resolvedFill: Color {
		fill ?? (colorScheme == .dark ? Color(hex: "#1C1C1E") : Color(hex: "#EEEEF0"))
	}

	private var geometry: ZagInstallControlGeometry { .of(mode) }
	private var motion: ZagInstallControlMotion.Spec {
		ZagInstallControlMotion.spec(toCompact: mode.isCompact, reduceMotion: reduceMotion)
	}

	/// The last pill shown, kept while compact so the label never changes
	/// mid-fade (Get stays "Get" while it contracts).
	@State private var lastPill: ZagInstallPill?

	private var pill: ZagInstallPill? {
		if case .pill(let pill) = mode { return pill }
		return lastPill
	}

	var body: some View {
		let g = geometry
		let m = motion
		Button(action: action) {
			ZStack {
				RoundedRectangle(cornerRadius: g.cornerRadius, style: .continuous)
					.fill(resolvedFill)
					.opacity(g.fillOpacity)
					.animation(Self.animation(m.fill), value: mode.isCompact)

				_label
					.opacity(g.labelOpacity)
					.animation(Self.animation(m.label), value: mode.isCompact)

				_ring
					.opacity(g.ringOpacity)
					.animation(Self.animation(m.ring), value: mode.isCompact)
			}
			.frame(width: g.width, height: g.height)
			.clipShape(RoundedRectangle(cornerRadius: g.cornerRadius, style: .continuous))
			.contentShape(RoundedRectangle(cornerRadius: g.cornerRadius, style: .continuous))
			.animation(Self.animation(m.morph), value: mode.isCompact)
		}
		.buttonStyle(.borderless)
		.disabled(!mode.isInteractive)
		.allowsHitTesting(mode.isInteractive)
		// Fixed action frame, trailing-anchored: the row never moves.
		.frame(width: ZagInstallControlGeometry.pillWidth, height: ZagInstallControlGeometry.pillHeight, alignment: .trailing)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(_accessibilityLabel))
		.accessibilityAddTraits(.isButton)
		.modifier(CancelAccessibility(cancel: cancelAction))
		.task(id: mode) { if case .pill(let p) = mode { lastPill = p } }
	}

	// MARK: Pieces

	@ViewBuilder
	private var _label: some View {
		if let pill {
			HStack(spacing: 4) {
				if let image = pill.systemImage {
					Image(systemName: image)
						.font(pill.title == nil
							? .system(size: pill.iconSize, weight: .regular)
							: .system(size: 15, weight: .bold))
				}
				if let title = pill.title {
					Text(title)
						.font(.system(size: 17, weight: .bold))
						.lineLimit(1)
						.minimumScaleFactor(0.7)
				}
			}
			.padding(.horizontal, pill.systemImage != nil && pill.title != nil ? 8 : 0)
			.foregroundStyle(resolvedTint)
			// Laid out at full pill width so contracting never reflows it.
			.frame(width: ZagInstallControlGeometry.pillWidth, height: ZagInstallControlGeometry.pillHeight)
			.fixedSize()
		}
	}

	@ViewBuilder
	private var _ring: some View {
		ZStack {
			Circle()
				.stroke(resolvedTint.opacity(0.22), lineWidth: 2.3)
			switch mode {
			case .progress(let value, _):
				Circle()
					.trim(from: 0, to: max(0.03, min(1, value)))
					.stroke(resolvedTint, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.animation(.smooth, value: value)
				if mode.glyph == .none, value >= 1 {
					Image(systemName: "checkmark")
						.font(.footnote.bold())
						.foregroundStyle(resolvedTint)
				}
			case .spinner:
				// Driven by the clock, so it never restarts when the row
				// scrolls off-screen and back.
				TimelineView(.animation(paused: reduceMotion)) { context in
					let period = 0.85
					let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
					Circle()
						.trim(from: 0.08, to: 0.72)
						.stroke(resolvedTint, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
						.rotationEffect(.degrees(turn * 360 - 90))
				}
			case .pill:
				EmptyView()
			}
			switch mode.glyph {
			case .pause:
				Image(systemName: "pause.fill").font(.footnote).foregroundStyle(resolvedTint)
			case .stop:
				Image(systemName: "square.fill").font(.footnote).foregroundStyle(resolvedTint)
			case .none:
				EmptyView()
			}
		}
		.frame(width: ZagInstallControlGeometry.circle, height: ZagInstallControlGeometry.circle)
	}

	private var _accessibilityLabel: String {
		switch mode {
		case .pill(let pill): return pill.accessibilityLabel
		case .progress(let value, let glyph):
			let percent = "\(Int((min(1, max(0, value)) * 100).rounded())) percent"
			switch glyph {
			case .pause: return "Downloading, \(percent). Pause"
			case .stop: return "Downloading, \(percent). Stop"
			case .none: return "Installing, \(percent)"
			}
		case .spinner: return "Preparing installation"
		}
	}

	static func animation(_ curve: ZagInstallControlMotion.Curve) -> Animation? {
		switch curve {
		case .none: return nil
		case .spring(let response, let damping): return .spring(response: response, dampingFraction: damping)
		case .easeIn(let duration, let delay): return .easeIn(duration: duration).delay(delay)
		case .easeOut(let duration): return .easeOut(duration: duration)
		case .easeInOut(let duration): return .easeInOut(duration: duration)
		}
	}
}

private struct CancelAccessibility: ViewModifier {
	let cancel: (() -> Void)?

	func body(content: Content) -> some View {
		if let cancel {
			content.accessibilityAction(named: Text("Cancel Installation"), cancel)
		} else {
			content
		}
	}
}

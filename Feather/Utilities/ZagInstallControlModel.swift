import Foundation

// The App Store-style install control as one element: a capsule (Get,
// Install, Update, Resume, Open …) that contracts symmetrically into the
// 31 pt progress circle and expands back. These are the rules;
// ZagInstallControlBody renders them. Foundation only, so the geometry is
// tested on the host.

enum ZagInstallGlyph: Equatable {
	case none
	/// Genuine pause is available (resumable download).
	case pause
	/// The existing stop square: tap cancels a download that can't resume.
	case stop
}

struct ZagInstallPill: Equatable {
	var title: String?
	var systemImage: String?
	/// Icon-only actions (download again) have no capsule fill.
	var filled = true
	var enabled = true
	/// Point size for an icon-only pill.
	var iconSize: Double = 25
	/// App Store's smaller secondary label (Resume): 15 pt semibold text
	/// and a matching symbol, instead of the 17 pt bold primary label.
	var compactLabel = false
	var accessibilityLabel: String

	/// Font for the title, and for the symbol beside it. Measurement and
	/// rendering both read this, so the pill width always fits the label.
	var labelFont: ZagInstallLabelFont {
		compactLabel ? .compact : .standard
	}
}

/// Label typography; `semibold` false means bold.
struct ZagInstallLabelFont: Equatable {
	let size: Double
	let semibold: Bool
	/// Symbol to title spacing when both are shown.
	let iconSpacing: Double

	/// Get, Update, Open: unchanged from ZagActionPill.
	static let standard = ZagInstallLabelFont(size: 17, semibold: false, iconSpacing: 5)
	/// Resume, measured from the App Store: 15 pt semibold.
	static let compact = ZagInstallLabelFont(size: 15, semibold: true, iconSpacing: 4.5)
}

/// What the compact circle shows.
enum ZagInstallRing: Equatable {
	/// Determinate ring, 0…1.
	case progress(Double, ZagInstallGlyph)
	/// Indeterminate ring (signing, packaging, Mobile Data Fix).
	case spinner(ZagInstallGlyph)

	var glyph: ZagInstallGlyph {
		switch self {
		case .progress(_, let glyph), .spinner(let glyph): return glyph
		}
	}

	/// Same kind of ring, ignoring the progress value. Progress ticks
	/// never count as a state change.
	func sameKind(as other: ZagInstallRing) -> Bool {
		switch (self, other) {
		case (.progress(_, let a), .progress(_, let b)): return a == b
		case (.spinner(let a), .spinner(let b)): return a == b
		default: return false
		}
	}
}

enum ZagInstallControlMode: Equatable {
	case pill(ZagInstallPill)
	case progress(Double, ZagInstallGlyph)
	case spinner(ZagInstallGlyph)

	var isCompact: Bool {
		if case .pill = self { return false }
		return true
	}

	var pill: ZagInstallPill? {
		if case .pill(let pill) = self { return pill }
		return nil
	}

	var ring: ZagInstallRing? {
		switch self {
		case .pill: return nil
		case .progress(let value, let glyph): return .progress(value, glyph)
		case .spinner(let glyph): return .spinner(glyph)
		}
	}

	var glyph: ZagInstallGlyph { ring?.glyph ?? .none }

	/// Taps reach the control only when they do something; otherwise they
	/// fall through to the row (Library rows open the app's details).
	var isInteractive: Bool {
		switch self {
		case .pill(let pill): return pill.enabled
		case .progress(_, let glyph), .spinner(let glyph): return glyph != .none
		}
	}
}

enum ZagInstallControlLayout {
	/// The layout slot every row reserves: the existing 88 × 34 pill.
	static let slotWidth = 88.0
	static let pillHeight = 34.0
	/// The existing progress ring.
	static let circle = 31.0
	static let ringStroke = 2.3
	/// ZagActionPill's horizontal padding.
	static let horizontalPadding = 14.0
	/// Label typography, unchanged from ZagActionPill.
	static let titleSize = ZagInstallLabelFont.standard.size
	/// Symbol to title spacing for icon + title pills.
	static let iconSpacing = ZagInstallLabelFont.standard.iconSpacing

	/// Pill width from the measured label: never narrower than the existing
	/// 88 pt pill, wider when the label needs it, so nothing truncates.
	static func pillWidth(contentWidth: Double) -> Double {
		max(slotWidth, (contentWidth + 2 * horizontalPadding).rounded(.up))
	}

	/// Minimum tap target around the 31 pt circle.
	static let compactHitWidth = 44.0

	/// Width of the tappable area: the pill itself, or a 44 pt target
	/// around the circle. Always centred on the slot.
	static func hitWidth(compact: Bool, pillWidth: Double) -> Double {
		compact ? max(circle, compactHitWidth) : pillWidth
	}

	/// Content width for a label: symbol, spacing, title.
	static func contentWidth(titleWidth: Double?, symbolWidth: Double?, spacing: Double = iconSpacing) -> Double {
		let parts = [symbolWidth, titleWidth].compactMap { $0 }
		return parts.reduce(0, +) + (parts.count == 2 ? spacing : 0)
	}
}

/// One frame of the morph. `compactness` is 0 for the pill and 1 for the
/// circle; it is the only animated value besides the pill width, so every
/// size and opacity below is derived from the same spring.
struct ZagInstallControlFrame: Equatable {
	var width: Double
	var height: Double
	var fillOpacity: Double
	var labelOpacity: Double
	var ringOpacity: Double

	var cornerRadius: Double { height / 2 }

	/// Edges around the fixed centre of the layout slot.
	func edges(centreX: Double) -> (left: Double, right: Double) {
		(centreX - width / 2, centreX + width / 2)
	}

	static func at(
		compactness rawT: Double,
		pillWidth: Double,
		contentWidth: Double,
		filled: Bool = true,
		reduceMotion: Bool = false
	) -> ZagInstallControlFrame {
		let t = clamp(rawT)
		typealias L = ZagInstallControlLayout
		// Reduce Motion: the shape doesn't resize in motion; it switches
		// size at the midpoint, while the contents cross-fade.
		let shapeT = reduceMotion ? (t < 0.5 ? 0 : 1) : t
		let width = pillWidth + (L.circle - pillWidth) * shapeT
		let height = L.pillHeight + (L.circle - L.pillHeight) * shapeT

		// The label is visible only while the capsule is wide enough to hold
		// it with padding, and it's gone before the ring starts to appear.
		let fits = reduceMotion ? 1 : clamp((width - contentWidth - L.horizontalPadding) / L.horizontalPadding)
		let label = min(fits, clamp(1 - t / 0.45))
		let ring = clamp((t - 0.5) / 0.5)
		// The capsule fill hands over to the ring's track as the circle settles.
		// Reduce Motion: the fill is gone before the size switches.
		let fill = filled ? (reduceMotion ? clamp(1 - t / 0.5) : clamp(1 - (t - 0.5) / 0.5)) : 0
		return .init(width: width, height: height, fillOpacity: fill, labelOpacity: label, ringOpacity: ring)
	}

	private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

enum ZagInstallControlMotion {
	/// Critically damped: no overshoot, so the width never passes its
	/// target and the circle never grows past 31 pt.
	static let response = 0.42
	static let dampingFraction = 1.0
	/// Reduce Motion cross-fade.
	static let reduceMotionDuration = 0.2

	/// The morph runs only when the control changes between pill and circle
	/// or between two different pills. Progress ticks never start it.
	static func shouldMorph(from old: ZagInstallControlMode, to new: ZagInstallControlMode) -> Bool {
		if old.isCompact != new.isCompact { return true }
		if let a = old.pill, let b = new.pill { return a != b }
		return false
	}
}

// MARK: - Keyframes

/// The morph as a list of frames sampled from the spring, so it can be
/// handed to Core Animation and run outside the app's main thread. A busy
/// main thread then can't freeze or skip it.
struct ZagInstallControlKeyframes: Equatable {
	var duration: Double
	var compactness: [Double]
	var pillWidths: [Double]
	var frames: [ZagInstallControlFrame]
}

extension ZagInstallControlMotion {
	/// Angular frequency of the critically damped spring.
	static var omega: Double { 2 * .pi / response }

	/// Critically damped spring progress 0 → 1 at `time` seconds.
	static func springProgress(_ time: Double) -> Double {
		guard time > 0 else { return 0 }
		let x = omega * time
		return 1 - (1 + x) * exp(-x)
	}

	/// Settled to within 0.1 %: (1 + x)e^-x = 0.001 at x ≈ 9.233.
	static var springDuration: Double { 9.233 / omega }

	/// Progress of a morph `elapsed` seconds after it started (used when a
	/// new state interrupts a morph that is still running).
	static func progress(elapsed: Double, reduceMotion: Bool) -> Double {
		if reduceMotion {
			let p = min(1, max(0, elapsed / reduceMotionDuration))
			return p * p * (3 - 2 * p)
		}
		return elapsed >= springDuration ? 1 : springProgress(elapsed)
	}

	static func keyframes(
		fromCompactness c0: Double, toCompactness c1: Double,
		fromWidth w0: Double, toWidth w1: Double,
		contentWidth: Double, filled: Bool, reduceMotion: Bool,
		count: Int = 72
	) -> ZagInstallControlKeyframes {
		let duration = reduceMotion ? reduceMotionDuration : springDuration
		var cs: [Double] = [], ws: [Double] = [], fs: [ZagInstallControlFrame] = []
		for i in 0...count {
			let time = duration * Double(i) / Double(count)
			let p = i == count ? 1 : progress(elapsed: time, reduceMotion: reduceMotion)
			let c = c0 + (c1 - c0) * p, w = w0 + (w1 - w0) * p
			cs.append(c); ws.append(w)
			fs.append(.at(compactness: c, pillWidth: w, contentWidth: contentWidth, filled: filled, reduceMotion: reduceMotion))
		}
		return .init(duration: duration, compactness: cs, pillWidths: ws, frames: fs)
	}
}

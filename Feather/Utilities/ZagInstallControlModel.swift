import Foundation

// The App Store-style install control as one element: a pill (Get, Install,
// Update, Resume, Open …) that contracts into the 31 pt progress circle and
// expands back. These are the rules; ZagInstallControl renders them.
// Foundation only, so geometry and timing are tested on the host.

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
	var accessibilityLabel: String
}

enum ZagInstallControlMode: Equatable {
	case pill(ZagInstallPill)
	/// Determinate ring, 0…1.
	case progress(Double, ZagInstallGlyph)
	/// Indeterminate ring (signing, packaging, Mobile Data Fix).
	case spinner(ZagInstallGlyph)

	var isCompact: Bool {
		if case .pill = self { return false }
		return true
	}

	var glyph: ZagInstallGlyph {
		switch self {
		case .pill: return .none
		case .progress(_, let glyph), .spinner(let glyph): return glyph
		}
	}

	/// Taps reach the control only when they do something; otherwise they
	/// fall through to the row (Library rows open the app's details).
	var isInteractive: Bool {
		switch self {
		case .pill(let pill): return pill.enabled
		case .progress(_, let glyph), .spinner(let glyph): return glyph != .none
		}
	}
}

struct ZagInstallControlGeometry: Equatable {
	/// The existing pill and ring sizes; none are new.
	static let pillWidth = 88.0
	static let pillHeight = 34.0
	static let circle = 31.0

	var width: Double
	var height: Double
	var cornerRadius: Double
	var fillOpacity: Double
	var labelOpacity: Double
	var ringOpacity: Double

	static func of(_ mode: ZagInstallControlMode) -> ZagInstallControlGeometry {
		switch mode {
		case .pill(let pill):
			return .init(width: pillWidth, height: pillHeight, cornerRadius: pillHeight / 2,
						 fillOpacity: pill.filled ? 1 : 0, labelOpacity: 1, ringOpacity: 0)
		case .progress, .spinner:
			return .init(width: circle, height: circle, cornerRadius: circle / 2,
						 fillOpacity: 0, labelOpacity: 0, ringOpacity: 1)
		}
	}

	/// Position inside the fixed 88 × 34 action frame: anchored to the
	/// trailing edge and centred vertically, so the row never reflows.
	var origin: (x: Double, y: Double) {
		(Self.pillWidth - width, (Self.pillHeight - height) / 2)
	}
}

enum ZagInstallControlMotion {
	enum Curve: Equatable {
		case none
		/// Critically damped enough that nothing overshoots.
		case spring(response: Double, damping: Double)
		case easeIn(duration: Double, delay: Double)
		case easeOut(duration: Double)
		case easeInOut(duration: Double)
	}

	struct Spec: Equatable {
		/// Width, height and corner radius.
		var morph: Curve
		var label: Curve
		var ring: Curve
		var fill: Curve
	}

	static let morphResponse = 0.42
	static let morphDamping = 0.9

	/// Contracting: the label leaves first, the ring arrives as the circle
	/// settles. Expanding: the ring leaves first, the label arrives as the
	/// pill reaches full width. Reduce Motion: no geometry animation, only
	/// short cross-fades.
	static func spec(toCompact: Bool, reduceMotion: Bool) -> Spec {
		if reduceMotion {
			let fade = Curve.easeInOut(duration: 0.15)
			return Spec(morph: .none, label: fade, ring: fade, fill: fade)
		}
		let morph = Curve.spring(response: morphResponse, damping: morphDamping)
		if toCompact {
			return Spec(morph: morph,
						label: .easeOut(duration: 0.12),
						ring: .easeIn(duration: 0.18, delay: 0.2),
						fill: .easeIn(duration: 0.18, delay: 0.2))
		}
		return Spec(morph: morph,
					label: .easeIn(duration: 0.18, delay: 0.16),
					ring: .easeOut(duration: 0.1),
					fill: .easeOut(duration: 0.12))
	}
}

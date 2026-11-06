import SwiftUI
import UIKit

// Loading placeholders: neutral shapes in the finished layout's geometry,
// with a soft highlight sweeping across them.

/// Neutral skeleton colours for light and dark appearance.
enum ZagSkeletonFill {
	/// The placeholder's surface (for example a card's artwork area).
	static let base = Color(uiColor: UIColor { traits in
		traits.userInterfaceStyle == .dark
			? UIColor(white: 1, alpha: 0.07)
			: UIColor(white: 0, alpha: 0.06)
	})
	/// Shapes drawn on that surface (icons, text bars, buttons).
	static let element = Color(uiColor: UIColor { traits in
		traits.userInterfaceStyle == .dark
			? UIColor(white: 1, alpha: 0.09)
			: UIColor(white: 0, alpha: 0.07)
	})
}

extension View {
	/// A soft highlight travelling left to right across this view, about
	/// 1.5 s per pass. It runs in Core Animation, so it stays smooth while
	/// the main thread is busy, and every shimmer shares one phase. With
	/// Reduce Motion the placeholder stays still. Clip the view to its
	/// shape after applying this.
	func zagShimmer() -> some View {
		modifier(ZagShimmerModifier())
	}
}

private struct ZagShimmerModifier: ViewModifier {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func body(content: Content) -> some View {
		content.overlay {
			if !reduceMotion {
				ZagShimmerLayer()
					.allowsHitTesting(false)
					.accessibilityHidden(true)
			}
		}
	}
}

private struct ZagShimmerLayer: UIViewRepresentable {
	func makeUIView(context: Context) -> ShimmerView { ShimmerView() }
	func updateUIView(_ view: ShimmerView, context: Context) {}

	final class ShimmerView: UIView {
		static let period: CFTimeInterval = 1.5
		private let band = CAGradientLayer()
		private var animatedWidth: CGFloat = 0
		private var foregroundObserver: NSObjectProtocol?

		override init(frame: CGRect) {
			super.init(frame: frame)
			isUserInteractionEnabled = false
			backgroundColor = .clear
			band.startPoint = CGPoint(x: 0, y: 0.5)
			band.endPoint = CGPoint(x: 1, y: 0.5)
			band.locations = [0, 0.5, 1]
			layer.addSublayer(band)
			updateColors()
			if #available(iOS 17.0, *) {
				registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShimmerView, _) in
					view.updateColors()
				}
			}
			// Restart after the app returns, in case the system dropped it.
			foregroundObserver = NotificationCenter.default.addObserver(
				forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
			) { [weak self] _ in
				self?.restart()
			}
		}

		required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		deinit {
			if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
		}

		override func layoutSubviews() {
			super.layoutSubviews()
			guard bounds.width != animatedWidth else { return }
			restart()
		}

		override func didMoveToWindow() {
			super.didMoveToWindow()
			restart()
		}

		private func updateColors() {
			let highlight = traitCollection.userInterfaceStyle == .dark
				? UIColor(white: 1, alpha: 0.10)
				: UIColor(white: 1, alpha: 0.55)
			// Soft edges: transparent, highlight, transparent.
			band.colors = [
				highlight.withAlphaComponent(0).cgColor,
				highlight.cgColor,
				highlight.withAlphaComponent(0).cgColor
			]
		}

		private func restart() {
			band.removeAnimation(forKey: "zagShimmer")
			animatedWidth = bounds.width
			guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
			let bandWidth = max(bounds.width * 0.55, 120)
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			// Starts fully left of the view and ends fully right of it, so
			// the loop never shows a jump.
			band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: bounds.height)
			CATransaction.commit()

			let sweep = CABasicAnimation(keyPath: "transform.translation.x")
			sweep.fromValue = 0
			sweep.toValue = bounds.width + bandWidth
			sweep.duration = Self.period
			sweep.repeatCount = .infinity
			sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			// One shared phase: every shimmer is at the same point of its pass.
			sweep.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
			band.add(sweep, forKey: "zagShimmer")
		}
	}
}

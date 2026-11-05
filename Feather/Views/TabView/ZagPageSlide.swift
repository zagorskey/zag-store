import UIKit
import UIKit.UIGestureRecognizerSubclass

// Settings → Zag Store → Main Pages → Sliding Pages: a quick slide when a
// main page is chosen from the dock. The old page moves a short way out and
// fades while the new one moves in, below the dock, which stays still.
// Only dock taps call this; links and routes switch pages without it.
enum ZagPageSlide {
	static let enabledKey = "Zag.slidingPages"
	static var isEnabled: Bool {
		UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
	}

	static let distance: CGFloat = 36
	static let duration: TimeInterval = 0.16

	/// The page as it looked when a finger touched the dock: by the time
	/// the selection reaches SwiftUI, UIKit has already swapped the page.
	private struct Pending {
		let snapshot: UIView
		let oldView: UIView
		let takenAt: Date
	}
	private static var pending: Pending?
	private static weak var observedDock: UITabBar?

	/// Adds a passive touch observer to the dock once it exists. Retries
	/// briefly while the tab bar is being built.
	static func attachToDock(attempts: Int = 10) {
		DispatchQueue.main.async {
			guard let tabs = tabBarController() else {
				if attempts > 0 {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attachToDock(attempts: attempts - 1) }
				}
				return
			}
			guard observedDock !== tabs.tabBar else { return }
			observedDock = tabs.tabBar
			tabs.tabBar.addGestureRecognizer(DockTouchObserver())
		}
	}

	fileprivate static func dockTouched() {
		pending = nil
		guard isEnabled, !UIAccessibility.isReduceMotionEnabled,
			  let tabs = tabBarController(),
			  let oldView = tabs.selectedViewController?.view, oldView.window != nil,
			  let snapshot = oldView.snapshotView(afterScreenUpdates: false) else { return }
		pending = Pending(snapshot: snapshot, oldView: oldView, takenAt: Date())
	}

	/// Call from the dock's selection setter. `order` is the dock's page
	/// order, which sets the direction.
	static func dockSelectionWillChange(from old: String, to new: String, order: [String]) {
		guard let taken = pending else { return }
		pending = nil
		guard old != new, isEnabled, !UIAccessibility.isReduceMotionEnabled,
			  Date().timeIntervalSince(taken.takenAt) < 1.5,
			  let from = order.firstIndex(of: old), let to = order.firstIndex(of: new),
			  let tabs = tabBarController(),
			  let container = taken.oldView.superview ?? tabs.selectedViewController?.view.superview else { return }
		let snapshot = taken.snapshot
		snapshot.frame = taken.oldView.frame
		snapshot.isUserInteractionEnabled = false
		if taken.oldView.superview === container {
			container.insertSubview(snapshot, aboveSubview: taken.oldView)
		} else if let newView = tabs.selectedViewController?.view, newView.superview === container {
			container.insertSubview(snapshot, aboveSubview: newView)
		} else {
			return
		}
		play(tabs: tabs, oldView: taken.oldView, snapshot: snapshot, direction: to > from ? 1 : -1, attempts: 4)
	}

	/// Waits for the tab bar to show the new page (a run-loop turn or two),
	/// then animates both.
	private static func play(tabs: UITabBarController, oldView: UIView, snapshot: UIView, direction: CGFloat, attempts: Int) {
		DispatchQueue.main.async {
			guard let newView = tabs.selectedViewController?.view, newView !== oldView, newView.window != nil else {
				if attempts > 0 {
					play(tabs: tabs, oldView: oldView, snapshot: snapshot, direction: direction, attempts: attempts - 1)
				} else {
					snapshot.removeFromSuperview()
				}
				return
			}
			let slide = CABasicAnimation(keyPath: "transform.translation.x")
			slide.fromValue = direction * distance
			slide.toValue = 0
			let fade = CABasicAnimation(keyPath: "opacity")
			fade.fromValue = 0
			fade.toValue = 1
			for animation in [slide, fade] {
				animation.duration = duration
				animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
				animation.fillMode = .backwards
			}
			newView.layer.add(slide, forKey: "zagPageSlide")
			newView.layer.add(fade, forKey: "zagPageFade")
			UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
				snapshot.transform = CGAffineTransform(translationX: -direction * distance, y: 0)
				snapshot.alpha = 0
			} completion: { _ in
				snapshot.removeFromSuperview()
			}
		}
	}

	private static func tabBarController() -> UITabBarController? {
		let windows = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap(\.windows)
		for window in windows where window.isKeyWindow {
			if let found = find(in: window.rootViewController) { return found }
		}
		return nil
	}

	private static func find(in controller: UIViewController?) -> UITabBarController? {
		guard let controller else { return nil }
		if let tabs = controller as? UITabBarController { return tabs }
		for child in controller.children {
			if let found = find(in: child) { return found }
		}
		return nil
	}
}

/// Notes a touch on the dock and then steps aside: it never recognises,
/// so it never claims, delays or cancels the dock's own touches.
private final class DockTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
	init() {
		super.init(target: nil, action: nil)
		cancelsTouchesInView = false
		delaysTouchesBegan = false
		delaysTouchesEnded = false
		delegate = self
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
		if numberOfTouches <= 1 { ZagPageSlide.dockTouched() }
		state = .failed
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
		true
	}
}

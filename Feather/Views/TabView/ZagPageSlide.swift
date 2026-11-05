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
	/// `contentFrame` is set when only the content under the top bar was
	/// captured (its frame in the navigation view).
	private struct Pending {
		let snapshot: UIView
		let oldView: UIView
		let contentFrame: CGRect?
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
			  let page = tabs.selectedViewController, page.view.window != nil else { return }
		// The content under the top bar, so the bar, its buttons and the
		// Local VPN badge stay put and only change.
		if let parts = parts(of: page),
		   let snapshot = parts.content.snapshotView(afterScreenUpdates: false) {
			pending = Pending(snapshot: snapshot, oldView: page.view,
							  contentFrame: parts.content.convert(parts.content.bounds, to: parts.navigation.view),
							  takenAt: Date())
		} else if let snapshot = page.view.snapshotView(afterScreenUpdates: false) {
			pending = Pending(snapshot: snapshot, oldView: page.view, contentFrame: nil, takenAt: Date())
		}
	}

	/// Call from the dock's selection setter. `order` is the dock's page
	/// order, which sets the direction.
	static func dockSelectionWillChange(from old: String, to new: String, order: [String]) {
		guard let taken = pending else { return }
		pending = nil
		guard old != new, isEnabled, !UIAccessibility.isReduceMotionEnabled,
			  Date().timeIntervalSince(taken.takenAt) < 1.5,
			  let from = order.firstIndex(of: old), let to = order.firstIndex(of: new),
			  let tabs = tabBarController() else { return }
		taken.snapshot.isUserInteractionEnabled = false
		play(tabs: tabs, taken: taken, direction: to > from ? 1 : -1, attempts: 5)
	}

	/// Animates as soon as the tab bar shows the new page (now, or within a
	/// run-loop turn or two).
	private static func play(tabs: UITabBarController, taken: Pending, direction: CGFloat, attempts: Int) {
		guard let page = tabs.selectedViewController, page.view !== taken.oldView, page.view.window != nil else {
			if attempts > 0 {
				DispatchQueue.main.async { play(tabs: tabs, taken: taken, direction: direction, attempts: attempts - 1) }
			}
			return
		}
		let snapshot = taken.snapshot
		let moving: UIView
		if let frame = taken.contentFrame, let parts = parts(of: page) {
			// Old content goes under the new page's top bar.
			let bar = parts.navigation.navigationBar
			snapshot.frame = frame
			if bar.superview === parts.navigation.view {
				parts.navigation.view.insertSubview(snapshot, belowSubview: bar)
			} else if let host = parts.content.superview {
				snapshot.frame = parts.navigation.view.convert(frame, to: host)
				host.insertSubview(snapshot, aboveSubview: parts.content)
			} else {
				return
			}
			moving = parts.content
		} else if taken.contentFrame == nil, let container = page.view.superview {
			snapshot.frame = taken.oldView.frame
			container.insertSubview(snapshot, aboveSubview: page.view)
			moving = page.view
		} else {
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
		moving.layer.add(slide, forKey: "zagPageSlide")
		moving.layer.add(fade, forKey: "zagPageFade")
		UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
			snapshot.transform = CGAffineTransform(translationX: -direction * distance, y: 0)
			snapshot.alpha = 0
		} completion: { _ in
			snapshot.removeFromSuperview()
		}
	}

	/// A page's navigation stack and the content shown under its top bar.
	private static func parts(of page: UIViewController) -> (navigation: UINavigationController, content: UIView)? {
		func navigation(in controller: UIViewController) -> UINavigationController? {
			if let nav = controller as? UINavigationController, nav.view.window != nil { return nav }
			for child in controller.children {
				if let found = navigation(in: child) { return found }
			}
			return nil
		}
		guard let nav = navigation(in: page), let content = nav.topViewController?.view,
			  content.window != nil, !nav.isNavigationBarHidden else { return nil }
		return (nav, content)
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

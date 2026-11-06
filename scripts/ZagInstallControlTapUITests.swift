import XCTest

/// Real taps on the shared install control inside rows that open details
/// on tap. One tap must produce exactly one intended action.
final class ZagInstallControlTapUITests: XCTestCase {
	private var app: XCUIApplication!

	override func setUp() {
		continueAfterFailure = false
		app = XCUIApplication()
		app.launch()
	}

	private var events: String { app.staticTexts["events"].label }

	private func reset() {
		app.buttons["reset"].tap()
		XCTAssertEqual(events, "none")
	}

	/// Taps `dx` points from the centre of a row's control.
	private func tapControl(_ name: String, dx: CGFloat = 0) {
		let control = app.descendants(matching: .any)["control-\(name)"]
		XCTAssertTrue(control.waitForExistence(timeout: 5), "control-\(name) missing")
		control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: dx, dy: 0)).tap()
	}

	private func assertEvents(_ expected: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
		// Let any delayed gesture finish before reading.
		Thread.sleep(forTimeInterval: 0.4)
		XCTAssertEqual(events, expected, message, file: file, line: line)
	}

	func testGetTapStartsInstallOnly() {
		reset(); tapControl("get")
		assertEvents("action:get=1", "Get must start the install once and never open details")
	}

	func testUpdateTapInButtonRowStartsUpdateOnly() {
		reset(); tapControl("update")
		assertEvents("action:update=1", "Update must run once and never open details")
	}

	func testProgressRingTapPausesOnly() {
		reset(); tapControl("ring")
		assertEvents("action:ring=1", "The download ring must pause/stop once and never open details")
	}

	func testSpinnerTapDoesNothing() {
		reset(); tapControl("spinner")
		assertEvents("none", "A spinner with no action must neither act nor open details")
	}

	func testResumeTapAtCentreAndEdgesResumesOnly() {
		reset(); tapControl("resume")
		assertEvents("action:resume=1", "Resume must resume once and never open details")
		// The Resume pill (113 pt) is wider than the 88 pt slot: its edges must work too.
		reset(); tapControl("resume", dx: 54)
		assertEvents("action:resume=1", "Resume's right edge (outside the 88 pt slot) must still resume")
		reset(); tapControl("resume", dx: -54)
		assertEvents("action:resume=1", "Resume's left edge (outside the 88 pt slot) must still resume")
	}

	func testOpenTapInButtonRowOpensOnly() {
		reset(); tapControl("open")
		assertEvents("action:open=1", "Open must launch once and never open details")
	}

	func testRestOfRowStillOpensDetails() {
		for name in ["get", "update", "ring", "spinner", "resume", "open"] {
			reset()
			app.staticTexts["title-\(name)"].tap()
			assertEvents("nav:\(name)=1", "Tapping the \(name) row outside the control must open details once")
		}
	}

	func testShrinkingPillStaysTappableThenReleasesItsArea() {
		// Resume → circle. The hit area covers the widest visible shape
		// until the morph is over (spring duration + 50 ms ≈ 670 ms), then
		// shrinks to the 44 pt circle target. The harness reports when the
		// tap landed, so the expected owner is exact whatever the latency.
		let holdMs = 670
		let control = app.descendants(matching: .any)["control-morphing"]
		XCTAssertTrue(control.waitForExistence(timeout: 5))
		let edge = control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 50, dy: 0))
		reset()
		app.buttons["morph"].tap()
		edge.tap()
		Thread.sleep(forTimeInterval: 0.4)
		let elapsed = Int(app.staticTexts["elapsed"].label) ?? -1
		XCTAssertGreaterThanOrEqual(elapsed, 0, "the tap must reach the control or the row")
		// `elapsed` is stamped at touch-up, but the hit test happens at
		// touch-down (up to ~150 ms earlier), so a tap just after the hold
		// may still land on the wide area. Either owner is right there, but
		// only ever one of them.
		if elapsed < holdMs {
			XCTAssertEqual(events, "action:morphing=1", "a tap \(elapsed) ms into the morph is on the shape and must belong to the control")
		} else if elapsed > holdMs + 250 {
			XCTAssertEqual(events, "nav:morphing=1", "a tap \(elapsed) ms after the morph is outside the circle and must open details")
		} else {
			XCTAssertTrue(["action:morphing=1", "nav:morphing=1"].contains(events), "a tap at the hold boundary (\(elapsed) ms) must produce exactly one event, got \(events)")
		}
		// Settled: that point is ordinary row again.
		Thread.sleep(forTimeInterval: 1.0)
		reset(); edge.tap()
		assertEvents("nav:morphing=1", "After the morph, the area outside the circle must open details again")
		// Circle → Resume: once expanded, the wide edge belongs to the control.
		app.buttons["morph"].tap()
		Thread.sleep(forTimeInterval: 1.0)
		reset(); edge.tap()
		assertEvents("action:morphing=1", "Once expanded, Resume's edge must belong to the control")
	}
}

import XCTest

/// Launch + first-run UI smoke tests. These are deliberately login-independent so they
/// never depend on a live Frigate server (which would make them flaky in CI). They prove
/// the app launches, presents a coherent first screen, and survives a background/foreground
/// cycle — the highest-value invariants for an automated gate.
final class ApexSightUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchPresentsOnboardingOrMainUI() {
        let app = XCUIApplication()
        app.launch()

        // The app must reach *some* interactive first screen quickly. On a fresh install
        // that's onboarding/login; on an existing install it's the tab bar. Accept either.
        let reachedUI = app.tabBars.firstMatch.waitForExistence(timeout: 12)
            || app.buttons.firstMatch.waitForExistence(timeout: 12)
            || app.textFields.firstMatch.waitForExistence(timeout: 12)
        XCTAssertTrue(reachedUI, "App did not present an interactive first screen within 12s")
    }

    func testSurvivesBackgroundForegroundCycle() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)

        XCUIDevice.shared.press(.home)
        let device = XCUIDevice.shared
        _ = device // silence unused in case of platform variance
        app.activate()

        // After returning to the foreground the app must still be alive (no crash on the
        // background→foreground transition — a core reliability requirement).
        XCTAssertEqual(app.state, .runningForeground, "App did not return to foreground cleanly")
    }

    func testLaunchPerformance() throws {
        // Performance baseline for app launch (Phase 1 performance test requirement).
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

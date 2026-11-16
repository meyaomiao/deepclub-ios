import XCTest
import UIKit

#if DEEPCLUB_LOCAL_INTEGRATION && DEBUG && targetEnvironment(simulator)
/// Real UI driver: ASWebAuthenticationSession, actual Go web/API, system Keychain.
/// Credentials are read from a private JSON file; xctestrun carries its path only.
/// Run the public secure-input sentinel first and inspect activity redaction.
/// No account transport is mocked and no shared pasteboard is touched.
final class P4LocalIntegrationUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["P4_REAL_UI"] == "1" else {
            throw XCTSkip("Explicit local P4 service and private test credentials required")
        }
    }

    private func privateJSON(_ key: String) throws -> [String: Any] {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    func test00SecureInputLoggingProbe() throws {
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        dismissSystemAlert()
        app.buttons["deepclub-browser-login"].tap()
        dismissSystemAlert()
        let user = app.webViews.textFields.firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 30))
        user.tap()
        user.typeText("P4-FOCUS-PUBLIC\t")
        let field = app.webViews.secureTextFields.firstMatch
        XCTAssertTrue(focusPassword(field), "Public probe requires confirmed secure-field keyboard focus")
        XCTAssertTrue(P4TypeRedactedText("P4-REDACTED-SENTINEL-ONLY"))
        XCTAssertTrue(user.value as? String == "P4-FOCUS-PUBLIC", "Redacted input must not alter username")
        // This sentinel is intentionally public. Inspect activities before using real credentials.
        capture("secure-input-probe")
    }

    func test01RealBrowserLogin() throws {
        let root = try privateJSON("P4_PRIVATE_ACCOUNTS_PATH")
        let accounts = try XCTUnwrap(root["accounts"] as? [String: Any])
        let a = try XCTUnwrap(accounts["a"] as? [String: Any])
        let username = try XCTUnwrap(a["username"] as? String)
        let password = try XCTUnwrap(a["password"] as? String)
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        dismissSystemAlert()
        let login = app.buttons["deepclub-browser-login"]
        XCTAssertTrue(login.waitForExistence(timeout: 15))
        capture("01-fresh-login")
        login.tap()
        dismissSystemAlert()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30), "System authentication browser must open real web page")
        let user = web.textFields.firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 25), "Actual browser login form")
        user.tap()
        user.typeText(username + "\t")
        let secret = web.secureTextFields.firstMatch
        guard focusPassword(secret) else {
            app.terminate()
            XCTFail("Secure-field keyboard focus was not confirmed; no private input sent")
            return
        }
        let typed = P4TypeRedactedText(password)
        guard user.value as? String == username else {
            // Never let XCTest capture a wrongly focused private value in failure snapshots.
            app.terminate()
            XCTFail("Private input target changed; application stopped before diagnostics")
            return
        }
        XCTAssertTrue(typed, "Redacted keyboard event must complete")
        let consent = web.checkBoxes.firstMatch
        if consent.exists && consent.value as? String != "1" { consent.tap() }
        web.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "登录", "Sign in")).firstMatch.tap()
        dismissPasswordSavePrompt()
        let approve = web.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "允许访问", "Allow access")).firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 30), "Actual explicit authorization page")
        capture("02-browser-approve")
        dismissPasswordSavePrompt()
        approve.tap()
        XCTAssertTrue(NSPredicate { _, _ in !login.exists && !web.exists }.wait(timeout: 30), "Real callback/token/bootstrap must complete")
        capture("03-authenticated")
    }

    func test02InspectCurrentUI() throws {
        app.activate()
        capture("current-ui")
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "current-ui-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test02bDismissExpiredOpenPrompt() throws {
        let cancel = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
    }

    func test03PairActualHost() throws {
        // The host driver privately delivers the real short-lived pair URL via
        // simctl openurl. Confirm the real OS route without logging its fragment.
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open"])).firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "OS route must foreground the product App")
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 40), "Actual Host hello protocol 3 must connect")
        capture("04-host-connected")
    }

    func test05NativeScenario() throws {
        let plan = try privateJSON("P4_UI_SCENARIO_PATH")
        let steps = try XCTUnwrap(plan["steps"] as? [[String: Any]])
        app.activate()
        XCTAssertFalse(app.buttons["deepclub-browser-login"].exists)
        for (index, step) in steps.enumerated() {
            let op = try XCTUnwrap(step["op"] as? String)
            let target = step["target"] as? String ?? ""
            let timeout = step["timeout"] as? Double ?? 15
            try XCTContext.runActivity(named: "Native scenario step \(index + 1): \(op)") { _ in
                switch op {
                case "tapButton", "tapButtonContains":
                    let format = op == "tapButton" ? "identifier == %@ OR label == %@" : "identifier == %@ OR label CONTAINS %@"
                    let button = app.buttons.matching(NSPredicate(format: format, target, target)).firstMatch
                    XCTAssertTrue(button.waitForExistence(timeout: timeout))
                    XCTAssertTrue(NSPredicate(block: { _, _ in button.isEnabled && button.isHittable }).wait(timeout: timeout), "Native button must be enabled and hittable before action")
                    button.tap()
                case "tapText":
                    let text = app.staticTexts[target].firstMatch
                    XCTAssertTrue(text.waitForExistence(timeout: timeout))
                    text.tap()
                case "typeComposer":
                    let input = app.textViews["composer-input"]
                    XCTAssertTrue(focusPassword(input))
                    XCTAssertTrue(P4TypeRedactedText(try XCTUnwrap(step["text"] as? String)))
                case "waitValue":
                    let input = app.textViews[target]
                    let expected = try XCTUnwrap(step["text"] as? String)
                    XCTAssertTrue(input.waitForExistence(timeout: timeout))
                    XCTAssertTrue(NSPredicate(block: { _, _ in (input.value as? String)?.contains(expected) == true }).wait(timeout: timeout))
                case "waitText":
                    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", target)).firstMatch.waitForExistence(timeout: timeout))
                case "waitButton":
                    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ OR label CONTAINS %@", target, target)).firstMatch.waitForExistence(timeout: timeout))
                case "swipeUp": app.swipeUp()
                case "swipeDown": app.swipeDown()
                case "capture": capture(target)
                case "dump":
                    let attachment = XCTAttachment(string: app.debugDescription)
                    attachment.name = target
                    attachment.lifetime = .keepAlways
                    add(attachment)
                default: XCTFail("Unsupported native scenario action")
                }
            }
        }
    }

    func test04RestartRestoresAccountAndHost() throws {
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons["deepclub-browser-login"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 40))
        capture("05-restart-restored")
    }

    func test06ObserveActualServerRevocation() throws {
        app.activate()
        XCTAssertTrue(app.buttons["deepclub-browser-login"].waitForExistence(timeout: 75), "Actual server revocation must clear the account and paired hosts")
        capture("ios-server-revoked-login")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["deepclub-browser-login"].waitForExistence(timeout: 15))
        capture("ios-revoked-restart-login")
    }

    private func dismissPasswordSavePrompt() {
        // The system password-save sheet temporarily replaces WebView in AX.
        // Decline only in this task's simulator; never save test account passwords.
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            let later = owner.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now", "Not now"])).firstMatch
            if later.waitForExistence(timeout: 2) { later.tap() }
        }
    }

    private func focusPassword(_ field: XCUIElement) -> Bool {
        guard field.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<3 {
            if field.debugDescription.contains("Keyboard Focused") { return true }
            field.tap()
            if NSPredicate(block: { _, _ in field.debugDescription.contains("Keyboard Focused") }).wait(timeout: 3) { return true }
        }
        return false
    }

    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            let alert = owner.alerts.firstMatch
            if alert.waitForExistence(timeout: 2) {
                let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label == %@ OR label == %@", "允许", "Allow", "继续", "Continue")).firstMatch
                if allow.exists { allow.tap() }
                else { alert.buttons.firstMatch.tap() }
            }
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension NSPredicate {
    func wait(timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: self, object: nil)], timeout: timeout) == .completed
    }
}
#endif

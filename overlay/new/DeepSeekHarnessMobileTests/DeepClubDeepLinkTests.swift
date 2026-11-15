import Foundation
import AuthenticationServices
import XCTest
@testable import DeepSeekHarnessMobile

private final class DeepClubSyntheticTransport: URLProtocol {
    static let lock = NSLock()
    private static var paths: [String] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; paths = [] }
    static func recordedPaths() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.paths.append(url.path); Self.lock.unlock()
        // Catch any attempted fetch of an address from a QR or an auth callback.
        guard url.host == "deepclub.net", ["/api/client/token", "/api/client/bootstrap", "/api/client/logout"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let value: [String: Any]
        if url.path == "/api/client/token" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }; data.append(contentsOf: bytes.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
            guard body?["client_type"] == "ios_remote", body?["code_verifier"] != nil else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            value = ["client_type": "ios_remote", "session_token": Data(repeating: 0xfb, count: 36).base64EncodedString(),
                     "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), "user": ["id": 7]]
        } else if url.path == "/api/client/bootstrap" {
            value = ["client_type": "ios_remote", "user": ["id": 7, "quota": 50],
                     "site": ["system_name": "synthetic", "quota_per_unit": 10], "device_limit": 10]
        } else { value = [:] }
        let data = try! JSONSerialization.data(withJSONObject: ["success": true, "data": value])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class DeepClubDeepLinkTests: XCTestCase {
    private final class Browser: DeepClubBrowserSession {
        let url: URL
        let completion: (URL?, Error?) -> Void
        var cancelled = false
        var startResult = true
        init(_ url: URL, _ completion: @escaping (URL?, Error?) -> Void) { self.url = url; self.completion = completion }
        func start() -> Bool { startResult }
        func cancel() { cancelled = true }
        func succeed(stateOverride: String? = nil) throws {
            let state = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
            let code = DeepClubProtocol.base64URL(Data(repeating: 9, count: 32))
            completion(URL(string: "deepclub://auth/callback?state=\(stateOverride ?? state)&code=\(code)"), nil)
        }
    }
    private final class Fixture {
        var browser: Browser?
        var saved: Data?
        var browserStarts = true
        var saveFails = false
        var paired: [String] = []
    }
    private func makeAccount(_ fixture: Fixture) -> DeepClubAccount {
        DeepClubSyntheticTransport.reset()
        var env = DeepClubAccountEnvironment()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepClubSyntheticTransport.self]
        env.transport = URLSession(configuration: configuration)
        env.defaults = UserDefaults(suiteName: "net.deepclub.test.\(UUID().uuidString)")!
        env.load = { nil }; env.save = { if fixture.saveFails { throw DeepClubError.storage }; fixture.saved = $0 }; env.clear = { fixture.saved = nil }
        env.installationID = { "synthetic-installation" }; env.healthChecks = false
        env.browser = { url, completion in
            let browser = Browser(url, completion); browser.startResult = fixture.browserStarts; fixture.browser = browser; return browser
        }
        return DeepClubAccount(environment: env)
    }
    private func pairURL(_ scheme: String = "https", expiry: Date = Date().addingTimeInterval(300), name: String = "Synthetic computer") throws -> URL {
        let payload: [String: Any] = ["version": 2, "gatewayId": "593027d4-bcc2-436b-a561-56172b98f82a",
            "gatewayName": name, "hostKey": "sha256:" + String(repeating: "a", count: 64),
            "protocols": ["dsh-mobile-v1"], "publicUrl": "wss://deepclub.net/ws/mobile/593027d4-bcc2-436b-a561-56172b98f82a",
            "endpoints": ["ws://192.168.1.24:3081/ws/mobile"],
            "pairingCode": DeepClubProtocol.base64URL(Data(repeating: 1, count: 32)), "expiresAt": expiry.timeIntervalSince1970 * 1000]
        let encoded = DeepClubProtocol.base64URL(try JSONSerialization.data(withJSONObject: payload))
        return URL(string: (scheme == "https" ? "https://deepclub.net/pair#" : "deepclub://pair#") + encoded)!
    }
    private func receive(_ url: URL, account: DeepClubAccount, fixture: Fixture) throws {
        try account.pairingIntent.receive(url, authenticated: account.session != nil) { fixture.paired.append($0) }
    }
    private func settle(_ account: DeepClubAccount) async throws {
        for _ in 0..<500 {
            if !account.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic browser callback did not settle")
    }

    func testFreshStoreKeepsQRImportAfterLoggedOutRestore() async throws {
        let shared = DeepClubAccount.shared
        XCTAssertNil(shared.session, "This test runs only on the new synthetic simulator account")
        let authenticated = shared.onAuthenticated
        let invalidated = shared.onInvalidated
        let unavailable = shared.onValidationUnavailable
        defer {
            shared.onAuthenticated = authenticated
            shared.onInvalidated = invalidated
            shared.onValidationUnavailable = unavailable
        }
        let suite = "net.deepclub.store.synthetic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosts = MultiGatewayStore(defaults: defaults)
        await hosts.waitUntilReady()
        XCTAssertTrue(hosts.isReady); XCTAssertTrue(hosts.profiles.isEmpty)
        XCTAssertNotNil(hosts.activeStore.pairingHandler)
        let initial = hosts.activeStore
        hosts.clearAccountConnections()
        XCTAssertFalse(initial === hosts.activeStore)
        XCTAssertNotNil(hosts.activeStore.pairingHandler)
        let raw = try pairURL().absoluteString
        XCTAssertThrowsError(try hosts.activeStore.pair(usingQRCode: raw))
        XCTAssertFalse(hosts.activeStore.gateway.transportActiveForTesting)
    }

    func testFreshUnpairedAndUnauthenticatedClientsNeverDialAnonymousLocalhost() async throws {
        let gateway = GatewayClient()
        gateway.connect(to: "ws://127.0.0.1:3080/ws/mobile")
        guard case .failed = gateway.state else { XCTFail("Missing account-bound identity must stop connection"); return }
        XCTAssertFalse(gateway.transportActiveForTesting)
        XCTAssertFalse(gateway.recoveryStateForTesting.wantsConnection)
        let fixture = Fixture(); let account = makeAccount(fixture)
        do {
            _ = try await account.connectionHeaders(endpoint: URL(string: "ws://127.0.0.1:3080/ws/mobile")!,
                gatewayID: "593027d4-bcc2-436b-a561-56172b98f82a", hostKey: "sha256:" + String(repeating: "a", count: 64),
                pairingCode: nil, deviceToken: nil)
            XCTFail("A logged-out account must not request an assertion")
        } catch DeepClubError.invalidSession { }
        XCTAssertTrue(DeepClubSyntheticTransport.recordedPaths().isEmpty)
        gateway.disconnect()
    }

    func testCustomAndUniversalLinkSurviveRealAuthorizationAndConsumeOnce() async throws {
        for scheme in ["https", "deepclub"] {
            let fixture = Fixture(); let account = makeAccount(fixture); let url = try pairURL(scheme)
            try receive(url, account: account, fixture: fixture)
            try receive(url, account: account, fixture: fixture)
            XCTAssertTrue(account.pairingIntent.hasPending); XCTAssertTrue(fixture.paired.isEmpty)
            account.onAuthenticated = { try! account.pairingIntent.consume { fixture.paired.append($0) } }
            account.login()
            XCTAssertTrue(account.pairingIntent.hasPending)
            let browser = try XCTUnwrap(fixture.browser)
            try browser.succeed()
            try browser.succeed() // Duplicate while the first token request is in flight.
            try await settle(account)
            XCTAssertEqual(account.session?.user.id, 7); XCTAssertNotNil(fixture.saved)
            XCTAssertEqual(fixture.paired.count, 1); XCTAssertFalse(account.pairingIntent.hasPending)
            try browser.succeed() // ASWebAuthenticationSession duplicate delivery.
            try await settle(account)
            XCTAssertThrowsError(try receive(url, account: account, fixture: fixture))
            XCTAssertEqual(fixture.paired.count, 1)
            XCTAssertEqual(DeepClubSyntheticTransport.recordedPaths(), ["/api/client/token", "/api/client/bootstrap"])
            await account.logout()
            XCTAssertNil(fixture.saved); XCTAssertNil(account.session)
        }
    }

    func testCancelledLoginAndLateSuccessCannotRestoreIntentOrSession() async throws {
        let fixture = Fixture(); let account = makeAccount(fixture)
        try receive(pairURL(), account: account, fixture: fixture)
        account.login(); let browser = try XCTUnwrap(fixture.browser)
        account.cancelLogin(); XCTAssertTrue(browser.cancelled)
        try browser.succeed()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(account.pairingIntent.hasPending); XCTAssertNil(account.session); XCTAssertNil(fixture.saved)
        XCTAssertTrue(DeepClubSyntheticTransport.recordedPaths().isEmpty)
    }

    func testBrowserCancellationAndFailureClearIntent() async throws {
        for failure in [ASWebAuthenticationSessionError(.canceledLogin) as Error, URLError(.cannotConnectToHost) as Error] {
            let fixture = Fixture(); let account = makeAccount(fixture)
            try receive(pairURL(), account: account, fixture: fixture); account.login()
            fixture.browser?.completion(nil, failure)
            try await settle(account)
            XCTAssertFalse(account.pairingIntent.hasPending); XCTAssertNil(account.session); XCTAssertNil(fixture.saved)
        }
    }

    func testBrowserStartAndCredentialSaveFailuresClearIntent() async throws {
        for failStart in [true, false] {
            let fixture = Fixture(); fixture.browserStarts = !failStart; fixture.saveFails = !failStart
            let account = makeAccount(fixture)
            try receive(pairURL(), account: account, fixture: fixture); account.login()
            if !failStart { try fixture.browser?.succeed() }
            try await settle(account)
            XCTAssertFalse(account.pairingIntent.hasPending); XCTAssertNil(account.session)
            XCTAssertNil(fixture.saved); XCTAssertTrue(fixture.paired.isEmpty); XCTAssertNotNil(account.error)
        }
    }

    func testWrongStateClearsIntentWithoutExchangingCode() async throws {
        let fixture = Fixture(); let account = makeAccount(fixture)
        try receive(pairURL(), account: account, fixture: fixture); account.login()
        try fixture.browser?.succeed(stateOverride: "attacker")
        try await settle(account)
        XCTAssertFalse(account.pairingIntent.hasPending); XCTAssertNotNil(account.error)
        XCTAssertTrue(DeepClubSyntheticTransport.recordedPaths().isEmpty)
    }

    func testExpiryIsRecheckedAfterBrowserSuccess() async throws {
        let fixture = Fixture(); let account = makeAccount(fixture); let now = Date()
        account.pairingIntent.clock = { now }
        try receive(pairURL(expiry: now.addingTimeInterval(1)), account: account, fixture: fixture)
        var rejectedExpiredIntent = false
        account.onAuthenticated = {
            do {
                try account.pairingIntent.consume { fixture.paired.append($0) }
                XCTFail("The intent expired while the browser was open")
            } catch DeepClubError.invalidQR { rejectedExpiredIntent = true }
            catch { XCTFail("Unexpected synthetic expiry error: \(error)") }
        }
        account.login(); account.pairingIntent.clock = { now.addingTimeInterval(2) }
        try fixture.browser?.succeed(); try await settle(account)
        XCTAssertNotNil(account.session); XCTAssertTrue(fixture.paired.isEmpty); XCTAssertFalse(account.pairingIntent.hasPending)
        XCTAssertTrue(rejectedExpiredIntent)
    }

    func testUnknownExpiredAndAuthCallbacksCannotBecomePairingRequests() throws {
        let fixture = Fixture(); let account = makeAccount(fixture)
        try receive(pairURL(), account: account, fixture: fixture)
        try receive(URL(string: "deepclub://auth/callback?code=ignored&state=ignored")!, account: account, fixture: fixture)
        XCTAssertTrue(account.pairingIntent.hasPending)
        for url in [URL(string: "https://attacker.invalid/pair#anything")!, URL(string: "deepclub://unknown")!, try pairURL(expiry: .distantPast)] {
            XCTAssertThrowsError(try receive(url, account: account, fixture: fixture))
            XCTAssertFalse(account.pairingIntent.hasPending)
        }
        let good = try pairURL()
        var payload = try JSONSerialization.jsonObject(with: DeepClubProtocol.decodeBase64URL(good.fragment!)!) as! [String: Any]
        payload["publicUrl"] = "wss://attacker.invalid/ws/mobile"
        let malicious = DeepClubProtocol.base64URL(try JSONSerialization.data(withJSONObject: payload))
        XCTAssertThrowsError(try receive(URL(string: "deepclub://pair#" + malicious)!, account: account, fixture: fixture))
        XCTAssertTrue(DeepClubSyntheticTransport.recordedPaths().isEmpty)
    }

    func testPairingFailureStillConsumesOnceAndLogoutClearsWaitingIntent() async throws {
        let fixture = Fixture(); let account = makeAccount(fixture); let url = try pairURL()
        try receive(url, account: account, fixture: fixture)
        var attempts = 0
        XCTAssertThrowsError(try account.pairingIntent.consume { _ in attempts += 1; throw DeepClubError.identity })
        XCTAssertThrowsError(try receive(pairURL(name: "Changed JSON same code"), account: account, fixture: fixture))
        var changedCase = try JSONSerialization.jsonObject(with: DeepClubProtocol.decodeBase64URL(url.fragment!)!) as! [String: Any]
        changedCase["gatewayId"] = (changedCase["gatewayId"] as! String).uppercased()
        changedCase["publicUrl"] = "ws://192.168.1.24:3081/ws/mobile"
        let replay = DeepClubProtocol.base64URL(try JSONSerialization.data(withJSONObject: changedCase))
        XCTAssertThrowsError(try receive(URL(string: "deepclub://pair#" + replay)!, account: account, fixture: fixture))
        XCTAssertEqual(attempts, 1)
        // Fresh intent in a fresh account is cleared by logout even before login.
        let second = self.makeAccount(Fixture())
        try second.pairingIntent.receive(url, authenticated: false) { _ in XCTFail("Must await login") }
        await second.logout(); XCTAssertFalse(second.pairingIntent.hasPending)
    }
}

import Foundation
import XCTest
#if canImport(DeepSeekHarnessMobile)
@testable import DeepSeekHarnessMobile
#endif

final class DeepClubProtocolTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_794_600_000)
    private let gatewayID = "593027d4-bcc2-436b-a561-56172b98f82a"
    private let hostKey = "sha256:" + String(repeating: "a", count: 64)
    private let code = DeepClubProtocol.base64URL(Data(repeating: 0, count: 32))
    private let phoneSession = Data(repeating: 0xfb, count: 36).base64EncodedString()

    private func pairing(_ changes: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = [
            "version": 2, "gatewayId": gatewayID, "gatewayName": "DeepClub test computer",
            "hostKey": hostKey, "protocols": ["dsh-mobile-v1", "deepclub-native-v1"],
            "publicUrl": "wss://deepclub.net/ws/mobile/\(gatewayID)",
            "endpoints": ["ws://192.168.1.24:3081/ws/mobile"],
            "pairingCode": code, "expiresAt": clock.addingTimeInterval(300).timeIntervalSince1970 * 1000,
        ]
        changes.forEach { value[$0.key] = $0.value }
        return DeepClubProtocol.base64URL(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }

    func testS256AndAuthorizationUseRemoteOnlyContract() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(DeepClubProtocol.challenge(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = DeepClubProtocol.authorizationURL(state: "state+&", verifier: verifier, deviceID: "fixture",
            name: "Fixture iPhone", version: "0.1.0")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "deepclub.net")
        XCTAssertEqual(query["client_type"], "ios_remote")
        XCTAssertEqual(query["client_id"], "deepclub-ios-remote-v1")
        XCTAssertEqual(query["redirect_uri"], "deepclub://auth/callback")
        XCTAssertEqual(query["state"], "state+&")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNil(query["code_verifier"])
    }

    func testCallbackRejectsWrongStateOriginAndDuplicateParameters() throws {
        let good = URL(string: "deepclub://auth/callback?state=fixture-state&code=\(code)")!
        XCTAssertEqual(try DeepClubProtocol.callbackCode(good, expectedState: "fixture-state"), code)
        for raw in [
            "deepclub://auth/callback?state=other&code=\(code)",
            "https://auth/callback?state=fixture-state&code=\(code)",
            "deepclub://user@auth/callback?state=fixture-state&code=\(code)",
            "deepclub://auth/callback?state=fixture-state&code=\(code)&code=\(code)",
            "deepclub://auth/callback?state=fixture-state&code=\(code)#extra",
            "deepclub://auth/callback?state=fixture-state&error=access_denied",
        ] {
            XCTAssertThrowsError(try DeepClubProtocol.callbackCode(URL(string: raw)!, expectedState: "fixture-state"))
        }
    }

    func testCallbackIsOneUseAndExpires() throws {
        let url = URL(string: "deepclub://auth/callback?state=fixture-state&code=\(code)")!
        var attempt = DeepClubAuthorizationAttempt(state: "fixture-state", verifier: code, createdAt: clock)
        XCTAssertEqual(try attempt.consume(url, now: clock), code)
        XCTAssertThrowsError(try attempt.consume(url, now: clock))
        var expired = DeepClubAuthorizationAttempt(state: "fixture-state", verifier: code, createdAt: clock)
        XCTAssertThrowsError(try expired.consume(url, now: clock.addingTimeInterval(300)))
    }

    func testUnifiedQRWorksForScanAndAppFallback() throws {
        let encoded = try pairing()
        for text in [encoded, "https://deepclub.net/pair#\(encoded)", "deepclub://pair#\(encoded)"] {
            let parsed = try DeepClubPairing.parse(text, now: clock)
            XCTAssertEqual(parsed.gatewayId, gatewayID)
            XCTAssertEqual(parsed.hostKey, hostKey)
            XCTAssertEqual(parsed.pairingCode, code)
        }
        for changes: [String: Any] in [
            ["version": 1], ["hostKey": "invalid"], ["gatewayId": "not-a-host"],
            ["protocols": ["deepclub-native-v1"]], ["pairingCode": "short"],
            ["gatewayName": " "], ["expiresAt": clock.timeIntervalSince1970 * 1000],
            ["expiresAt": clock.addingTimeInterval(601).timeIntervalSince1970 * 1000],
        ] {
            XCTAssertThrowsError(try DeepClubPairing.parse(pairing(changes), now: clock))
        }
        for prefix in ["https://other.invalid/pair#", "https://deepclub.net/pair?code=leak#", "deepclub://auth/callback#"] {
            XCTAssertThrowsError(try DeepClubPairing.parse(prefix + encoded, now: clock))
        }
    }

    func testPhoneSessionIsOnlySentToExactDeepClubRelay() throws {
        for endpoint in ["ws://192.168.1.24:3081/ws/mobile", "wss://another.invalid/ws/mobile/\(gatewayID)"] {
            let headers = try DeepClubProtocol.connectionHeaders(endpoint: URL(string: endpoint)!, gatewayID: gatewayID,
                hostKey: hostKey, assertion: code, phoneSession: phoneSession, pairCode: code, deviceToken: nil)
            XCTAssertNil(headers["X-DeepClub-Session"])
            XCTAssertNil(headers["Authorization"])
            XCTAssertEqual(headers["Sec-WebSocket-Protocol"], "dsh-mobile-v1, dsh-pair.\(code)")
        }
        let relay = URL(string: "wss://deepclub.net/ws/mobile/\(gatewayID)")!
        let headers = try DeepClubProtocol.connectionHeaders(endpoint: relay, gatewayID: gatewayID, hostKey: hostKey,
            assertion: code, phoneSession: phoneSession, pairCode: nil, deviceToken: code)
        XCTAssertEqual(headers["X-DeepClub-Session"], phoneSession)
        XCTAssertEqual(headers["Authorization"], "Bearer \(code)")
        XCTAssertThrowsError(try DeepClubProtocol.connectionHeaders(endpoint: relay, gatewayID: gatewayID,
            hostKey: hostKey, assertion: code, phoneSession: code, pairCode: nil, deviceToken: code))
    }

    func testTokenResponseAcceptsActualBackendSessionAndRejectsModelKey() throws {
        var body: [String: Any] = [
            "client_type": "ios_remote", "session_token": phoneSession,
            "expires_at": ISO8601DateFormatter().string(from: clock.addingTimeInterval(3600)),
            "user": ["id": 1, "username": "fixture"],
        ]
        func response() throws -> Data { try JSONSerialization.data(withJSONObject: ["success": true, "data": body]) }
        XCTAssertTrue(phoneSession.contains("+"))
        XCTAssertEqual(try DeepClubProtocol.tokenResponse(response(), now: clock).session_token, phoneSession)
        body["api_key"] = "not-allowed"
        XCTAssertThrowsError(try DeepClubProtocol.tokenResponse(response(), now: clock))
        body.removeValue(forKey: "api_key")
        body["token_id"] = 123
        XCTAssertThrowsError(try DeepClubProtocol.tokenResponse(response(), now: clock))
        body.removeValue(forKey: "token_id")
        body["client_type"] = "agent"
        XCTAssertThrowsError(try DeepClubProtocol.tokenResponse(response(), now: clock))
        body["client_type"] = "ios_remote"
        body["expires_at"] = ISO8601DateFormatter().string(from: clock)
        XCTAssertThrowsError(try DeepClubProtocol.tokenResponse(response(), now: clock))
    }
}

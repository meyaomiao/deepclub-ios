import Foundation
import CryptoKit

// DeepClub remote-only wire contract. No model credentials belong in this module.
enum DeepClubProtocol {
    static let origin = URL(string: "https://deepclub.net")!
    static let clientID = "deepclub-ios-remote-v1"
    static let clientType = "ios_remote"
    static let callback = "deepclub://auth/callback"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              value.count % 4 != 1 else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64URL(data) == value else { return nil }
        return data
    }
    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    static func validHostKey(_ value: String) -> Bool {
        value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    static func opaqueToken(_ value: String) -> Bool {
        decodeBase64URL(value)?.count == 32
    }
    // Client sessions are 36 random bytes in standard Base64; authorization
    // codes, pairing codes and assertions use 32 bytes in unpadded Base64URL.
    static func sessionToken(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), data.count == 36 else { return false }
        return data.base64EncodedString() == value
    }
    static func authorizationURL(state: String, verifier: String, deviceID: String, name: String, version: String) -> URL {
        var parts = URLComponents(url: origin.appendingPathComponent("client/authorize"), resolvingAgainstBaseURL: false)!
        let values = ["client_id": clientID, "client_type": clientType, "platform": "ios",
                      "redirect_uri": callback, "code_challenge_method": "S256", "code_challenge": challenge(verifier),
                      "state": state, "device_id": deviceID, "device_name": String(name.prefix(100)), "app_version": version]
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    static func callbackCode(_ url: URL, expectedState: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "deepclub", parts.host == "auth", parts.path == "/callback",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)).isSubset(of: ["code", "state", "error"]),
              items.first(where: { $0.name == "state" })?.value == expectedState else { throw DeepClubError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw DeepClubError.authorizationDenied }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              opaqueToken(code) else { throw DeepClubError.invalidCallback }
        return code
    }
    static func isRelay(_ url: URL, gatewayID: String) -> Bool {
        url.scheme == "wss" && url.host == "deepclub.net" && url.port == nil &&
            url.path == "/ws/mobile/\(gatewayID)" && url.user == nil && url.password == nil &&
            url.query == nil && url.fragment == nil
    }
    static func connectionHeaders(endpoint: URL, gatewayID: String, hostKey: String, assertion: String,
                                  phoneSession: String, pairCode: String?, deviceToken: String?) throws -> [String: String] {
        guard validHostKey(hostKey), opaqueToken(assertion) else { throw DeepClubError.identity }
        guard sessionToken(phoneSession) else { throw DeepClubError.invalidSession }
        var headers = ["X-DeepClub-Assertion": assertion, "X-DeepClub-Host-Key": hostKey,
                       "Sec-WebSocket-Protocol": "dsh-mobile-v1"]
        if let pairCode {
            guard opaqueToken(pairCode) else { throw DeepClubError.identity }
            headers["Sec-WebSocket-Protocol"] = "dsh-mobile-v1, dsh-pair.\(pairCode)"
        } else {
            guard let deviceToken, opaqueToken(deviceToken) else { throw DeepClubError.pairAgain }
            headers["Authorization"] = "Bearer \(deviceToken)"
        }
        if isRelay(endpoint, gatewayID: gatewayID) { headers["X-DeepClub-Session"] = phoneSession }
        return headers
    }
    static func tokenResponse(_ data: Data, now: Date = .now) throws -> DeepClubSession {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true, let body = root["data"] as? [String: Any],
              body["api_key"] == nil, body["token_id"] == nil,
              body["client_type"] as? String == clientType else { throw DeepClubError.invalidSession }
        let session = try JSONDecoder().decode(DeepClubSession.self, from: JSONSerialization.data(withJSONObject: body))
        guard sessionToken(session.session_token), session.user.id > 0,
              let expiry = ISO8601DateFormatter().date(from: session.expires_at), expiry > now else {
            throw DeepClubError.invalidSession
        }
        return session
    }
}

struct DeepClubSession: Codable, Equatable, Sendable {
    let client_type: String
    let session_token: String
    var expires_at: String
    let user: User
    struct User: Codable, Equatable, Sendable { let id: Int; var username: String?; var display_name: String? }
}

struct DeepClubPairing: Codable, Hashable, Sendable {
    var version: Int
    var publicUrl: String
    var pairingCode: String
    var expiresAt: Double
    var gatewayId: String?
    var gatewayName: String?
    var endpoints: [String]?
    var protocols: [String]?
    var hostKey: String?
    var endpoint: URL? { URL(string: publicUrl) }
    var expirationDate: Date { Date(timeIntervalSince1970: expiresAt / 1_000) }

    static func parse(_ raw: String, now: Date = .now) throws -> Self {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 16384 else { throw DeepClubError.invalidQR }
        let encoded: String
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("deepclub://") {
            guard let parts = URLComponents(string: trimmed), parts.user == nil, parts.password == nil,
                  parts.port == nil, parts.query == nil, let fragment = parts.fragment,
                  (parts.scheme == "https" && parts.host == "deepclub.net" && parts.path == "/pair") ||
                  (parts.scheme == "deepclub" && parts.host == "pair" && parts.path.isEmpty) else { throw DeepClubError.invalidQR }
            encoded = fragment
        } else { encoded = trimmed }
        guard let data = DeepClubProtocol.decodeBase64URL(encoded) else { throw DeepClubError.invalidQR }
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.version == 2, let id = payload.gatewayId,
              id.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil,
              let key = payload.hostKey, DeepClubProtocol.validHostKey(key),
              let name = payload.gatewayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 128,
              payload.protocols?.contains("dsh-mobile-v1") == true,
              DeepClubProtocol.opaqueToken(payload.pairingCode), payload.expiresAt.isFinite,
              payload.expirationDate > now, payload.expirationDate.timeIntervalSince(now) <= 600,
              (payload.endpoints?.count ?? 0) <= 16 else { throw DeepClubError.invalidQR }
        return payload
    }
}

// A cancelled/replaced authorization can never consume a callback or revive a session.
struct DeepClubAuthorizationAttempt {
    let id = UUID()
    let state: String
    let verifier: String
    let createdAt: Date
    var consumed = false
    mutating func consume(_ url: URL, now: Date = .now) throws -> String {
        guard !consumed, now.timeIntervalSince(createdAt) < 300 else { throw DeepClubError.invalidCallback }
        let code = try DeepClubProtocol.callbackCode(url, expectedState: state)
        consumed = true
        return code
    }
}

/// Serializes a gateway credential write with account invalidation. The active
/// flag and the Keychain operation share one lock, so an actor that was queued
/// before logout cannot restore a device token after the account was cleared.
final class DeepClubCredentialGate: @unchecked Sendable {
    static let shared = DeepClubCredentialGate()
    private let lock = NSLock()
    private var active = false

    func activate() {
        lock.lock()
        defer { lock.unlock() }
        active = true
    }

    func withActiveAccount<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard active else { throw DeepClubError.invalidSession }
        try Task.checkCancellation()
        return try operation()
    }

    func invalidate(clearing operation: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        active = false
        try operation()
    }
}

enum DeepClubError: LocalizedError {
    case invalidCallback, authorizationDenied, invalidSession, invalidQR, identity, pairAgain, unavailable, storage
    var errorDescription: String? {
        switch self {
        case .invalidCallback: String(localized: "授权回调无效或已失效，请重新登录。")
        case .authorizationDenied: String(localized: "已取消授权。")
        case .invalidSession: String(localized: "账号授权已失效，请重新登录并扫码连接。")
        case .invalidQR: String(localized: "配对二维码无效、已过期或不支持 DeepClub，请在电脑重新生成。")
        case .identity: String(localized: "主机身份不匹配，已停止连接，请重新扫码。")
        case .pairAgain: String(localized: "电脑配对已失效，请重新扫码连接。")
        case .unavailable: String(localized: "DeepClub 暂时无法验证账号，请稍后重试。")
        case .storage: String(localized: "无法清理安全凭据，请解锁设备后重试。")
        }
    }
}

/// Holds a validated intent only in process memory. Replay identifiers are hashes,
/// retained until expiry even across logout; raw QR URLs never enter preferences/logs.
@MainActor
final class DeepClubPairingIntent {
    private var pending: DeepClubPairing?
    private var consumed: [String: Date] = [:]
    var clock: () -> Date = { .now }
    var hasPending: Bool { pending != nil }

    func clear() { pending = nil }

    func receive(_ url: URL, authenticated: Bool, pair: (String) throws -> Void) throws {
        // ASWebAuthenticationSession owns auth callbacks. They cannot become QR data.
        if url.scheme == "deepclub", url.host == "auth", url.path == "/callback" { return }
        do {
            guard (url.scheme == "deepclub" && url.host == "pair") ||
                  (url.scheme == "https" && url.host == "deepclub.net" && url.path == "/pair") else {
                throw DeepClubError.invalidQR
            }
            let payload = try PairingPayloadParser.parse(url.absoluteString, now: clock())
            consumed = consumed.filter { $0.value > clock() }
            let id = identity(payload)
            guard consumed[id] == nil else { throw DeepClubError.pairAgain }
            // Both onOpenURL and Universal Link delivery may report the same QR.
            if let pending, identity(pending) == id { return }
            pending = payload
            if authenticated { try consume(pair: pair) }
        } catch {
            clear()
            // Decoder/URL errors must not put untrusted payload text in alerts/logs.
            throw (error as? DeepClubError) ?? DeepClubError.invalidQR
        }
    }

    func consume(pair: (String) throws -> Void) throws {
        guard let payload = pending else { return }
        pending = nil // Clear before any callback/reentrant delivery, even on failure.
        let encoded = DeepClubProtocol.base64URL(try JSONEncoder().encode(payload))
        _ = try PairingPayloadParser.parse(encoded, now: clock())
        let id = identity(payload)
        guard consumed[id] == nil else { throw DeepClubError.pairAgain }
        consumed[id] = payload.expirationDate
        try pair(encoded)
    }

    private func identity(_ payload: DeepClubPairing) -> String {
        DeepClubProtocol.challenge((payload.gatewayId ?? "").lowercased() + ":" + payload.pairingCode)
    }
}

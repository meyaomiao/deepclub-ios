import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import Security
import UIKit

struct DeepClubBootstrap: Decodable {
    let client_type: String
    let user: User
    let site: Site
    let device_limit: Int
    struct User: Decodable { let id: Int; let quota: Double }
    struct Site: Decodable { let system_name: String; let quota_per_unit: Double }
    var balance: Double { site.quota_per_unit > 0 ? user.quota / site.quota_per_unit : 0 }
}
private struct DeepClubEnvelope<Value: Decodable>: Decodable { let success: Bool; let data: Value? }

struct DeepClubDevice: Decodable, Identifiable {
    let id: Int
    let device_name: String
    let platform: String
    let client_type: String
    let is_current: Bool
}

protocol DeepClubBrowserSession: AnyObject {
    func start() -> Bool
    func cancel()
}
extension ASWebAuthenticationSession: DeepClubBrowserSession {}

// Production defaults use Keychain/ASWebAuthenticationSession. Tests inject only
// this boundary, so the real state/PKCE/token/bootstrap path still executes.
struct DeepClubAccountEnvironment {
    var transport = URLSession(configuration: .ephemeral, delegate: DeepClubRedirectBlocker(), delegateQueue: nil)
    var defaults = UserDefaults.standard
    var load: () throws -> Data? = { try DeepClubKeychain.load("session") }
    var save: (Data) throws -> Void = { try DeepClubKeychain.save($0, account: "session") }
    var clear: () throws -> Void = {
        try DeepClubKeychain.delete("session")
        try DeepClubKeychain.deleteService("net.deepclub.remote.gateway-token")
    }
    var installationID: () throws -> String = { try DeepClubKeychain.installationID() }
    var browser: ((URL, @escaping (URL?, Error?) -> Void) -> any DeepClubBrowserSession)?
    var healthChecks = true
}

@MainActor
final class DeepClubAccount: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DeepClubAccount()
    @Published private(set) var session: DeepClubSession?
    @Published private(set) var bootstrap: DeepClubBootstrap?
    @Published private(set) var devices: [DeepClubDevice] = []
    @Published private(set) var busy = false
    @Published var error: String?
    let pairingIntent = DeepClubPairingIntent()
    var onAuthenticated: (() -> Void)?
    var onInvalidated: (() -> Void)?
    var onValidationUnavailable: (() -> Void)?
    private var generation = UUID()
    private var attempt: DeepClubAuthorizationAttempt?
    private var browser: (any DeepClubBrowserSession)?
    private var healthTask: Task<Void, Never>?
    private let environment: DeepClubAccountEnvironment
    private let logoutMarker = "deepclub.account.requiresCleanup"

    override convenience init() { self.init(environment: DeepClubAccountEnvironment()) }

    init(environment: DeepClubAccountEnvironment) {
        self.environment = environment
        super.init()
        do {
            if environment.defaults.bool(forKey: logoutMarker) {
                try clearCredentials()
            } else if let data = try environment.load() {
                let stored = try JSONDecoder().decode(DeepClubSession.self, from: data)
                guard stored.client_type == DeepClubProtocol.clientType,
                      DeepClubProtocol.sessionToken(stored.session_token),
                      let expires = ISO8601DateFormatter().date(from: stored.expires_at), expires > .now else {
                    throw DeepClubError.invalidSession
                }
                session = stored
                DeepClubCredentialGate.shared.activate()
                startHealthChecks()
            }
        } catch { self.error = error.localizedDescription; invalidate() }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    func login() {
        guard !busy else { return }
        invalidate(preservingPairingIntent: true)
        guard !environment.defaults.bool(forKey: logoutMarker) else { pairingIntent.clear(); return }
        do {
            let pending = DeepClubAuthorizationAttempt(state: try random(), verifier: try random(), createdAt: .now)
            attempt = pending
            let captured = generation
            busy = true
            error = nil
            let deviceID = try environment.installationID()
            let url = DeepClubProtocol.authorizationURL(state: pending.state, verifier: pending.verifier,
                deviceID: deviceID, name: UIDevice.current.name,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            let completion: (URL?, Error?) -> Void = { [weak self] url, failure in
                Task { @MainActor in
                    guard let self, self.generation == captured else { return }
                    self.browser = nil
                    if let url { await self.finishAuthorization(url, generation: captured) }
                    else {
                        self.attempt = nil
                        self.busy = false
                        self.pairingIntent.clear()
                        if (failure as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                            self.error = failure?.localizedDescription ?? DeepClubError.authorizationDenied.localizedDescription
                        }
                    }
                }
            }
            let auth: any DeepClubBrowserSession
            if let factory = environment.browser { auth = factory(url, completion) }
            else {
                let systemBrowser = ASWebAuthenticationSession(url: url, callbackURLScheme: "deepclub", completionHandler: completion)
                systemBrowser.presentationContextProvider = self
                systemBrowser.prefersEphemeralWebBrowserSession = true
                auth = systemBrowser
            }
            browser = auth
            guard auth.start() else { throw DeepClubError.unavailable }
        } catch { attempt = nil; browser = nil; busy = false; pairingIntent.clear(); self.error = error.localizedDescription }
    }

    private func finishAuthorization(_ url: URL, generation captured: UUID) async {
        guard captured == generation, var pending = attempt, !pending.consumed else { return }
        do {
            let code = try pending.consume(url)
            attempt = pending
            let payload = ["grant_type": "authorization_code", "client_id": DeepClubProtocol.clientID,
                           "client_type": DeepClubProtocol.clientType, "redirect_uri": DeepClubProtocol.callback,
                           "code": code, "code_verifier": pending.verifier]
            let data = try await request("api/client/token", method: "POST", body: payload, token: nil, generation: captured)
            guard captured == generation, !Task.isCancelled else { return }
            let received = try DeepClubProtocol.tokenResponse(data)
            // Validate the returned account/type before saving any authenticated state.
            let rawBootstrap = try await request("api/client/bootstrap", token: received.session_token, generation: captured)
            let info = try decode(DeepClubBootstrap.self, rawBootstrap)
            guard info.client_type == DeepClubProtocol.clientType, info.user.id == received.user.id,
                  captured == generation, !Task.isCancelled else { throw DeepClubError.invalidSession }
            try environment.save(JSONEncoder().encode(received))
            session = received
            DeepClubCredentialGate.shared.activate()
            bootstrap = info
            attempt = nil
            busy = false
            onAuthenticated?()
            startHealthChecks()
        } catch {
            guard captured == generation else { return }
            attempt = nil; busy = false; pairingIntent.clear(); self.error = error.localizedDescription
        }
    }

    func cancelLogin() { invalidate() }

    func logout() async {
        let previous = session?.session_token
        invalidate()
        if let previous {
            do { _ = try await request("api/client/logout", method: "POST", token: previous) }
            catch DeepClubError.invalidSession { /* Already revoked or expired. */ }
            catch { self.error = String(localized: "本机已退出，服务端暂未确认退出；可在网页设备管理中撤销此设备。") }
        }
    }

    // Synchronous tombstone + cancellation precedes deletion. Late callbacks cannot write credentials.
    func invalidate(preservingPairingIntent: Bool = false) {
        if !preservingPairingIntent { pairingIntent.clear() }
        environment.defaults.set(true, forKey: logoutMarker)
        generation = UUID()
        browser?.cancel(); browser = nil; attempt = nil
        healthTask?.cancel(); healthTask = nil
        session = nil; bootstrap = nil; devices = []; busy = false
        onInvalidated?()
        do { try clearCredentials() }
        catch { self.error = DeepClubError.storage.localizedDescription }
    }

    private func clearCredentials() throws {
        try DeepClubCredentialGate.shared.invalidate {
            try environment.clear()
        }
        environment.defaults.set(false, forKey: logoutMarker)
    }

    private func startHealthChecks() {
        guard environment.healthChecks else { return }
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session != nil else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func refresh() async {
        guard let current = session else { return }
        let captured = generation
        do {
            let data = try await request("api/client/bootstrap", token: current.session_token, generation: captured)
            let info = try decode(DeepClubBootstrap.self, data)
            guard captured == generation else { return }
            guard info.client_type == DeepClubProtocol.clientType, info.user.id == current.user.id,
                  info.site.quota_per_unit.isFinite, info.site.quota_per_unit > 0,
                  info.user.quota.isFinite else { throw DeepClubError.invalidSession }
            bootstrap = info
            let rawDevices = try await request("api/client/devices", token: current.session_token, generation: captured)
            let list = try decode([DeepClubDevice].self, rawDevices)
            guard captured == generation else { return }
            devices = list
        } catch is CancellationError { return }
        catch {
            guard captured == generation else { return }
            if case DeepClubError.invalidSession = error { invalidate() }
            else { onValidationUnavailable?() }
            self.error = error.localizedDescription
        }
    }

    func connectionHeaders(endpoint: URL, gatewayID: String, hostKey: String,
                           pairingCode: String?, deviceToken: String?) async throws -> [String: String] {
        guard let current = session, !environment.defaults.bool(forKey: logoutMarker) else { throw DeepClubError.invalidSession }
        let captured = generation
        let raw = try await request("api/client/remote/assertion", method: "POST",
            body: ["gateway_id": gatewayID, "host_key": hostKey, "purpose": pairingCode == nil ? "connect" : "pair"],
            token: current.session_token, generation: captured)
        struct Assertion: Decodable { let assertion: String; let expires_at: String }
        let value = try decode(Assertion.self, raw)
        guard captured == generation, session?.session_token == current.session_token, !Task.isCancelled else { throw CancellationError() }
        guard let expires = ISO8601DateFormatter().date(from: value.expires_at), expires > Date(),
              expires.timeIntervalSinceNow <= 150 else { throw DeepClubError.identity }
        return try DeepClubProtocol.connectionHeaders(endpoint: endpoint, gatewayID: gatewayID, hostKey: hostKey,
            assertion: value.assertion, phoneSession: current.session_token, pairCode: pairingCode, deviceToken: deviceToken)
    }

    private func request(_ path: String, method: String = "GET", body: [String: String]? = nil,
                         token: String?, generation captured: UUID? = nil) async throws -> Data {
        var request = URLRequest(url: DeepClubProtocol.origin.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await environment.transport.data(for: request)
        if let captured, captured != generation { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, response.url?.host == "deepclub.net",
              data.count <= 1024 * 1024 else { throw DeepClubError.unavailable }
        if http.statusCode == 401 {
            if token != nil, captured == generation {
                invalidate()
                if !environment.defaults.bool(forKey: logoutMarker) {
                    error = DeepClubError.invalidSession.localizedDescription
                }
            }
            throw DeepClubError.invalidSession
        }
        if http.statusCode == 403 { throw DeepClubError.identity }
        guard (200..<300).contains(http.statusCode) else { throw DeepClubError.unavailable }
        if let expiry = http.value(forHTTPHeaderField: "X-Client-Session-Expires-At"),
           ISO8601DateFormatter().date(from: expiry) != nil, var stored = session,
           stored.session_token == token, captured == generation {
            stored.expires_at = expiry
            try environment.save(JSONEncoder().encode(stored))
            session = stored
        }
        return data
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(DeepClubEnvelope<T>.self, from: data)
        guard envelope.success, let result = envelope.data else { throw DeepClubError.unavailable }
        return result
    }
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DeepClubError.storage }
        return DeepClubProtocol.base64URL(Data(bytes))
    }
}

private final class DeepClubRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum DeepClubKeychain {
    private static let service = "net.deepclub.remote.account"
    static func load(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw DeepClubError.storage }
        return data
    }
    static func save(_ data: Data, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(base.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw DeepClubError.storage }
        } else if status != errSecSuccess { throw DeepClubError.storage }
    }
    static func delete(_ account: String) throws {
        try remove([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrAccount as String: account])
    }
    static func deleteService(_ service: String) throws {
        try remove([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service])
    }
    private static func remove(_ query: [String: Any]) throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw DeepClubError.storage }
    }
    static func installationID() throws -> String {
        if let value = try load("installation"), let id = String(data: value, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try save(Data(id.utf8), account: "installation")
        return id
    }
}

import Foundation
import AppKit
import CryptoKit
import Network

// MARK: - errors

enum GoogleAuthError: Error, LocalizedError {
    case missingCredentials
    case notConnected
    case listenerFailed(String)
    case userCancelled
    case denied(String)
    case tokenExchangeFailed(String)
    case noRefreshToken

    var errorDescription: String? {
        switch self {
        case .missingCredentials:          return L("gcal.err.missing_credentials")
        case .notConnected:                return L("gcal.err.not_connected")
        case .listenerFailed(let m):       return L("gcal.err.listener", m)
        case .userCancelled:               return L("gcal.err.cancelled")
        case .denied(let m):               return L("gcal.err.denied", m)
        case .tokenExchangeFailed(let m):  return L("gcal.err.token", m)
        case .noRefreshToken:              return L("gcal.err.no_refresh_token")
        }
    }
}

// MARK: - credentials

/// Client id / secret / refresh token for the user's *own* Google OAuth client.
///
/// Dayflow ships no credentials of its own. An OAuth client id can't be kept
/// secret in an open-source desktop binary — anyone can read it out with
/// `strings` — and Google's quota and consent screen are attached to whoever
/// owns the client, so baking mine in would put every user's calendar traffic
/// under my project. Each user creates a **Desktop app** client in their own
/// Google Cloud project and pastes it here, exactly like the LLM API key.
enum GoogleCredentials {
    private static let clientIDKey = "dayflow.gcal.clientID"
    private static let keychainService = "dayflow.gcal"
    private static let secretAccount = "client-secret"
    private static let refreshAccount = "refresh-token"

    static var clientID: String {
        get { UserDefaults.standard.string(forKey: clientIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey) }
    }

    static var clientSecret: String? {
        get { keychainRead(account: secretAccount) }
        set {
            if let v = newValue, !v.isEmpty { keychainWrite(account: secretAccount, value: v) }
            else { keychainDelete(account: secretAccount) }
        }
    }

    static var refreshToken: String? {
        get { keychainRead(account: refreshAccount) }
        set {
            if let v = newValue, !v.isEmpty { keychainWrite(account: refreshAccount, value: v) }
            else { keychainDelete(account: refreshAccount) }
        }
    }

    /// Both halves of the client are on file. Says nothing about whether the
    /// user has actually granted access yet — that's `isConnected`.
    static var hasClient: Bool {
        !clientID.isEmpty && !(clientSecret ?? "").isEmpty
    }

    static var isConnected: Bool {
        hasClient && !(refreshToken ?? "").isEmpty
    }

    /// Drop the grant but keep the client id/secret — reconnecting shouldn't
    /// mean pasting the client back in.
    static func forgetGrant() {
        refreshToken = nil
    }

    // MARK: keychain

    private static func keychainRead(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func keychainWrite(account: String, value: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainDelete(account: String) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - PKCE

enum PKCE {
    /// RFC 7636 code verifier: 43–128 chars from the unreserved set.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// base64url without padding — the `+/=` of standard base64 would need
    /// escaping in a query string and Google rejects the padded form.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - loopback redirect receiver

/// A one-shot HTTP listener on `127.0.0.1:<ephemeral>`.
///
/// This is why Dayflow needs no web server, no domain, and no nginx. Google's
/// installed-app flow lets a desktop client register `http://127.0.0.1` with
/// *any* port, so the app opens a socket for the few seconds the consent
/// screen is up, reads the `?code=` off the single request the browser makes
/// to it, and closes.
///
/// The alternative — a custom `com.googleusercontent.apps.*` URL scheme —
/// would have to be declared in `Info.plist` at build time, but the client id
/// is the user's and isn't known until they paste it. Loopback sidesteps that
/// entirely.
final class LoopbackAuthReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()
    private var finished = false

    /// Binds and returns the port the browser should be pointed at.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only. The consent redirect is the only thing that should
        // ever reach this socket.
        params.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw GoogleAuthError.listenerFailed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener

        // NWListener assigns the port asynchronously; wait briefly for it.
        let deadline = Date().addingTimeInterval(3)
        while listener.port == nil || listener.port?.rawValue == 0 {
            if Date() > deadline {
                throw GoogleAuthError.listenerFailed("no port assigned")
            }
            usleep(20_000)
        }
        guard let port = listener.port?.rawValue else {
            throw GoogleAuthError.listenerFailed("no port assigned")
        }
        return port
    }

    /// Resolves with the authorization code, or throws if the user denied or
    /// walked away. `timeout` is generous — the consent screen can involve a
    /// password, 2FA, and an account picker.
    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(GoogleAuthError.userCancelled))
        }
        defer {
            timeoutTask.cancel()
            stop()
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if finished {
                lock.unlock()
                cont.resume(throwing: GoogleAuthError.userCancelled)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: internals

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result = Self.parse(requestLine: request)

            let body: String
            switch result {
            case .success:
                body = Self.page(title: L("gcal.browser.done_title"), message: L("gcal.browser.done_body"))
            case .failure:
                body = Self.page(title: L("gcal.browser.failed_title"), message: L("gcal.browser.failed_body"))
            }
            let http = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            conn.send(content: Data(http.utf8), completion: .contentProcessed { _ in
                conn.cancel()
                self.finish(result)
            })
        }
    }

    /// Pulls `code` (or `error`) out of the request line the browser sends:
    /// `GET /?code=4/0Ab...&scope=... HTTP/1.1`
    static func parse(requestLine raw: String) -> Result<String, Error> {
        guard let line = raw.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(path)") else {
            return .failure(GoogleAuthError.denied("malformed redirect"))
        }
        let items = comps.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            // `access_denied` is what "Cancel" on the consent screen sends.
            return .failure(err == "access_denied"
                            ? GoogleAuthError.userCancelled
                            : GoogleAuthError.denied(err))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(GoogleAuthError.denied("no code in redirect"))
        }
        return .success(code)
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else {
            finished = true
            lock.unlock()
            return
        }
        finished = true
        continuation = nil
        lock.unlock()
        cont.resume(with: result)
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Dayflow</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; background: #17181c; color: #e6e7ea;
                 display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
          .card { text-align: center; }
          h1 { font-size: 20px; margin: 0 0 8px; }
          p { color: #9a9ba1; margin: 0; font-size: 14px; }
        </style></head>
        <body><div class="card"><h1>\(title)</h1><p>\(message)</p></div></body></html>
        """
    }
}

// MARK: - OAuth client

/// Authorization-code + PKCE against Google's installed-app endpoints.
/// Stateless apart from the in-memory access token cache.
actor GoogleOAuth {
    static let shared = GoogleOAuth()

    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    private var accessToken: String?
    private var accessTokenExpiry: Date = .distantPast

    /// Runs the full consent flow and stores the refresh token. Must be driven
    /// from the main actor — it opens a browser window.
    func connect(clientID: String, clientSecret: String) async throws {
        let verifier = PKCE.makeVerifier()
        let receiver = LoopbackAuthReceiver()
        let port = try receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: Self.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            // Without `offline` + `consent` Google hands back an access token
            // only, and the next launch would have to send the user through
            // the browser all over again.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        guard let url = comps.url else { throw GoogleAuthError.denied("bad auth url") }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        let code = try await receiver.waitForCode()
        let tokens = try await exchange(
            fields: [
                "code": code,
                "client_id": clientID,
                "client_secret": clientSecret,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code",
                "code_verifier": verifier,
            ]
        )
        guard let refresh = tokens.refreshToken else { throw GoogleAuthError.noRefreshToken }
        GoogleCredentials.refreshToken = refresh
        cache(tokens)
    }

    /// A live access token, refreshing if the cached one is within a minute of
    /// expiry. Every API call goes through here.
    func validAccessToken() async throws -> String {
        if let token = accessToken, Date() < accessTokenExpiry.addingTimeInterval(-60) {
            return token
        }
        guard GoogleCredentials.hasClient else { throw GoogleAuthError.missingCredentials }
        guard let refresh = GoogleCredentials.refreshToken, !refresh.isEmpty else {
            throw GoogleAuthError.notConnected
        }
        let tokens = try await exchange(
            fields: [
                "client_id": GoogleCredentials.clientID,
                "client_secret": GoogleCredentials.clientSecret ?? "",
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ]
        )
        cache(tokens)
        guard let token = tokens.accessToken else { throw GoogleAuthError.noRefreshToken }
        return token
    }

    func invalidate() {
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    // MARK: internals

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func cache(_ tokens: TokenResponse) {
        accessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600))
    }

    private func exchange(fields: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError.tokenExchangeFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAuthError.tokenExchangeFailed("HTTP \(http.statusCode) — \(body.prefix(200))")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleAuthError.tokenExchangeFailed(error.localizedDescription)
        }
    }

    /// `application/x-www-form-urlencoded`. `URLComponents` would leave `+`
    /// alone, and a `+` in a client secret would decode server-side as a
    /// space — hence the explicit allowed set.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .sorted()
            .joined(separator: "&")
    }
}

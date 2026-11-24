import CryptoKit
import Darwin
import Foundation

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var tokenType: String
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date,
                tokenType: String = "Bearer", scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
    }

    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

public protocol TokenStore: Sendable {
    func load() -> OAuthTokens?
    func save(_ tokens: OAuthTokens)
    func clear()
}

public struct KeychainTokenStore: TokenStore {
    private let account: String

    public init(account: String = "googleDriveOAuthTokens") {
        self.account = account
    }

    public func load() -> OAuthTokens? {
        guard let raw = Keychain.get(account), let data = raw.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(tokens), let str = String(data: data, encoding: .utf8) else { return }
        Keychain.set(str, for: account)
    }

    public func clear() {
        Keychain.set("", for: account)
    }
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    public init(_ initial: OAuthTokens? = nil) {
        self.tokens = initial
    }

    public func load() -> OAuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: OAuthTokens) {
        lock.lock()
        self.tokens = tokens
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        tokens = nil
        lock.unlock()
    }
}

public struct GoogleOAuthConfig: Codable, Equatable, Sendable {
    public static let driveFileScope = "https://www.googleapis.com/auth/drive.file"
    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    public static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"

    public var clientID: String
    public var clientSecret: String
    public var scope: String

    public init(clientID: String = "", clientSecret: String = "", scope: String = GoogleOAuthConfig.driveFileScope) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
    }

    public var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Settings may override the desktop client shipped with a release.
    public func usingDefault(_ bundled: GoogleOAuthConfig) -> GoogleOAuthConfig {
        guard isConfigured else { return bundled }
        if clientID == bundled.clientID && clientSecret.isEmpty {
            return GoogleOAuthConfig(clientID: clientID, clientSecret: bundled.clientSecret, scope: scope)
        }
        return self
    }
}

public struct PKCE: Equatable, Sendable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String

    public init(codeVerifier: String? = nil, state: String? = nil) {
        let verifier = codeVerifier ?? Self.randomURLSafeString(byteCount: 32)
        self.codeVerifier = verifier
        self.codeChallenge = Self.challenge(for: verifier)
        self.state = state ?? Self.randomURLSafeString(byteCount: 16)
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    public static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal loopback HTTP server bound to `127.0.0.1:0` for native macOS OAuth 2.0 PKCE redirects.
public final class LoopbackOAuthServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    public let port: UInt16
    public var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    public init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SyncError.invalidResponse("Failed to open loopback socket (errno \(errno))")
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SyncError.invalidResponse("Failed to bind loopback socket (errno \(errno))")
        }
        guard Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw SyncError.invalidResponse("Failed to listen on loopback socket (errno \(errno))")
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(fd, sa, &boundLen)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw SyncError.invalidResponse("Failed to query loopback port")
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    deinit {
        close()
    }

    public func close() {
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    /// Waits for a single OAuth redirect callback and returns the authorization code.
    public func waitForCode(expectedState: String, timeout: TimeInterval = 300) async throws -> String {
        let fd = listenFD
        guard fd >= 0 else { throw SyncError.cancelled }
        return try await Task.detached(priority: .userInitiated) { [weak self] in
            defer { self?.close() }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let timeoutMS = Int32(min(timeout * 1000, Double(Int32.max)))
            let ready = Darwin.poll(&pfd, 1, timeoutMS)
            guard ready > 0 else {
                throw ready == 0 ? SyncError.offline("Sign-in timed out waiting for browser redirect.") : SyncError.cancelled
            }
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &clientLen)
                }
            }
            guard clientFD >= 0 else { throw SyncError.cancelled }
            defer { Darwin.close(clientFD) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(clientFD, &buffer, buffer.count)
            guard n > 0 else { throw SyncError.invalidResponse("Empty OAuth callback request") }
            let rawRequest = String(decoding: buffer[0..<n], as: UTF8.self)
            let result = Self.parseCallbackRequest(rawRequest, expectedState: expectedState)

            let html: String
            switch result {
            case .success:
                html = "<!doctype html><meta charset=utf-8><title>Margins</title><body style='font-family:-apple-system,sans-serif;max-width:460px;margin:80px auto;text-align:center'><h2>Signed in to Google Drive</h2><p>You can close this tab and return to Margins.</p></body>"
            case .failure(let err):
                html = "<!doctype html><meta charset=utf-8><title>Margins</title><body style='font-family:-apple-system,sans-serif;max-width:460px;margin:80px auto;text-align:center'><h2>Sign-in failed</h2><p>\(err.localizedDescription)</p></body>"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            _ = response.withCString { Darwin.write(clientFD, $0, strlen($0)) }
            return try result.get()
        }.value
    }

    public static func parseCallbackRequest(_ raw: String, expectedState: String) -> Result<String, SyncError> {
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first ?? raw.split(separator: "\n", maxSplits: 1).first else {
            return .failure(.invalidResponse("Malformed HTTP request"))
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(.invalidResponse("Missing request path"))
        }
        let target = String(parts[1])
        guard let comps = URLComponents(string: "http://127.0.0.1" + target) else {
            return .failure(.invalidResponse("Invalid callback URL"))
        }
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        if let err = items["error"] {
            return .failure(.invalidResponse("Google OAuth error: \(err)"))
        }
        guard items["state"] == expectedState else {
            return .failure(.invalidResponse("OAuth state mismatch"))
        }
        guard let code = items["code"], !code.isEmpty else {
            return .failure(.invalidResponse("Missing authorization code"))
        }
        return .success(code)
    }
}

public actor GoogleOAuthClient {
    public private(set) var config: GoogleOAuthConfig
    private let tokenStore: TokenStore
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(config: GoogleOAuthConfig,
                tokenStore: TokenStore = KeychainTokenStore(),
                http: HTTPClient = URLSessionHTTPClient(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.tokenStore = tokenStore
        self.http = http
        self.now = now
    }

    public func updateConfig(_ config: GoogleOAuthConfig) {
        self.config = config
    }

    public var isConnected: Bool {
        tokenStore.load() != nil
    }

    public func currentTokens() -> OAuthTokens? {
        tokenStore.load()
    }

    public func authorizationURL(redirectURI: String, pkce: PKCE) throws -> URL {
        guard config.isConfigured else {
            throw SyncError.missingConfiguration("Enter a Google OAuth Client ID in Settings → Sync.")
        }
        var comps = URLComponents(string: GoogleOAuthConfig.authorizationEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        guard let url = comps.url else {
            throw SyncError.invalidResponse("Failed to construct OAuth authorization URL")
        }
        return url
    }

    @discardableResult
    public func exchangeCode(_ code: String, redirectURI: String, codeVerifier: String) async throws -> OAuthTokens {
        guard config.isConfigured else {
            throw SyncError.missingConfiguration("Enter a Google OAuth Client ID in Settings → Sync.")
        }
        var params: [(String, String)] = [
            ("code", code),
            ("client_id", config.clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code"),
        ]
        let secret = config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            params.append(("client_secret", secret))
        }
        let tokens = try await postTokenRequest(params: params, fallbackRefreshToken: nil)
        tokenStore.save(tokens)
        return tokens
    }

    @discardableResult
    public func refreshTokens(_ current: OAuthTokens) async throws -> OAuthTokens {
        guard config.isConfigured else {
            throw SyncError.missingConfiguration("Google OAuth Client ID is missing.")
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw SyncError.notAuthenticated
        }
        var params: [(String, String)] = [
            ("refresh_token", refreshToken),
            ("client_id", config.clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("grant_type", "refresh_token"),
        ]
        let secret = config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            params.append(("client_secret", secret))
        }
        let refreshed = try await postTokenRequest(params: params, fallbackRefreshToken: refreshToken)
        tokenStore.save(refreshed)
        return refreshed
    }

    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = tokenStore.load() else {
            throw SyncError.notAuthenticated
        }
        if !forceRefresh, !tokens.isExpired(at: now()) {
            return tokens.accessToken
        }
        let refreshed = try await refreshTokens(tokens)
        return refreshed.accessToken
    }

    public func disconnect() async {
        if let tokens = tokenStore.load() {
            let tokenToRevoke = tokens.refreshToken ?? tokens.accessToken
            var req = URLRequest(url: URL(string: GoogleOAuthConfig.revokeEndpoint)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formEncoded([("token", tokenToRevoke)])
            _ = try? await http.data(for: req)
        }
        tokenStore.clear()
    }

    private func postTokenRequest(params: [(String, String)], fallbackRefreshToken: String?) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: GoogleOAuthConfig.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncoded(params)
        req.timeoutInterval = 30

        let (data, resp) = try await http.data(for: req)
        guard (200..<300).contains(resp.statusCode) else {
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            throw SyncError.httpError(resp.statusCode, snippet)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = obj["access_token"] as? String else {
            throw SyncError.invalidResponse("Missing access_token in OAuth token response")
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? Double(obj["expires_in"] as? Int ?? 3600)
        let refreshToken = (obj["refresh_token"] as? String) ?? fallbackRefreshToken
        let tokenType = (obj["token_type"] as? String) ?? "Bearer"
        let scope = obj["scope"] as? String
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(expiresIn),
            tokenType: tokenType,
            scope: scope
        )
    }

    public static func formEncoded(_ params: [(String, String)]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/?")
        let body = params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

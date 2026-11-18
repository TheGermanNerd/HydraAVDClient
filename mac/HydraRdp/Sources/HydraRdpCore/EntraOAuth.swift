import Foundation
import Security

public struct EntraTokenSet: Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func needsRefresh(now: Date = Date(), skew: TimeInterval = 300) -> Bool {
        now.addingTimeInterval(skew) >= expiresAt
    }
}

public struct EntraAuthorization: Equatable {
    public var url: URL
    public var state: String
    public var clientID: String
    public var redirectURI: String
    public var tenant: String
}

public enum EntraOAuth {
    /// Microsoft Remote Desktop public client. The AVD feed accepts this identity.
    public static let clientID = "a85cf173-4192-42f8-81fa-777a763e6e2c"
    public static let redirectURI = "ms-appx-web://Microsoft.AAD.BrokerPlugin/\(clientID)"
    public static let tenant = "common"
    public static let scope = "https://www.wvd.microsoft.com/.default offline_access openid profile"

    public static func start() throws -> EntraAuthorization {
        let state = randomToken()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "login.microsoftonline.com"
        components.path = "/\(tenant)/oauth2/v2.0/authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        guard let url = components.url else { throw EntraOAuthError("Could not build the Entra sign-in URL.") }
        return EntraAuthorization(
            url: url,
            state: state,
            clientID: clientID,
            redirectURI: redirectURI,
            tenant: tenant
        )
    }

    public static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw EntraOAuthError(description)
        }
        let state = items.first(where: { $0.name == "state" })?.value
        guard state == expectedState else { throw EntraOAuthError("Entra returned an unexpected sign-in response.") }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw EntraOAuthError("Entra did not return an authorization code.")
        }
        return code
    }

    public static func exchange(
        authorization: EntraAuthorization,
        code: String,
        session: URLSession = .shared
    ) async throws -> EntraTokenSet {
        try await token(
            tenant: authorization.tenant,
            form: [
                "client_id": authorization.clientID,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": authorization.redirectURI,
                "scope": scope
            ],
            session: session
        )
    }

    public static func refresh(
        refreshToken: String,
        session: URLSession = .shared
    ) async throws -> EntraTokenSet {
        try await token(
            tenant: tenant,
            form: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": scope
            ],
            session: session
        )
    }

    private static func token(tenant: String, form: [String: String], session: URLSession) async throws -> EntraTokenSet {
        guard let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token") else {
            throw EntraOAuthError("Could not build the token URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(form).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw EntraOAuthError(tokenErrorDescription(data: data, status: status))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw EntraOAuthError("Entra did not return an access token.")
        }
        let refresh = json["refresh_token"] as? String
        let lifetime = json["expires_in"] as? Double ?? (json["expires_in"] as? Int).map(Double.init) ?? 3600
        return EntraTokenSet(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
    }

    private static func tokenErrorDescription(data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let description = (json["error_description"] as? String) ?? (json["error"] as? String)
            if let description, !description.isEmpty {
                return "Entra token request failed (\(status)): \(description)"
            }
        }
        return "Entra token request failed (\(status))."
    }

    private static func formURLEncoded(_ fields: [String: String]) -> String {
        fields.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.sorted().joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

public struct EntraOAuthError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public struct EntraAccountProfile: Equatable {
    public var name: String
    public var username: String

    public init(name: String, username: String) {
        self.name = name
        self.username = username
    }
}

public enum EntraIdentity {
    /// Reads the display name and username from an Entra access token. The signature is not checked;
    /// the token is only used after Entra issued it to this app.
    public static func profile(accessToken: String) -> EntraAccountProfile? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2, let data = base64URLDecode(String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = claim(json, "name") ?? ""
        let username = claim(json, "preferred_username") ?? claim(json, "upn") ?? claim(json, "email") ?? ""
        guard !name.isEmpty || !username.isEmpty else { return nil }
        return EntraAccountProfile(name: name.isEmpty ? username : name, username: username)
    }

    private static func claim(_ json: [String: Any], _ key: String) -> String? {
        guard let value = json[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

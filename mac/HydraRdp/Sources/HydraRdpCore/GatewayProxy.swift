import CFNetwork
import Foundation

/// UDP and HTTP-proxy choices for one FreeRDP launch.
public struct SessionConnection: Equatable {
    public var useUDP: Bool
    /// Value for FreeRDP `/proxy`, without the `/proxy:` prefix.
    public var proxyArgument: String

    public init(useUDP: Bool, proxyArgument: String) {
        self.useUDP = useUDP
        self.proxyArgument = proxyArgument
    }

    /// UDP on and the proxy forced off, matching the General settings defaults.
    public static let windowsAppDefaults = SessionConnection(useUDP: true, proxyArgument: GatewayProxy.ignore)
}

/// Turns the HTTP-proxy switch and a proxy list into one FreeRDP argument.
public enum GatewayProxy {
    public static let ignore = "ignore"

    /// `enabled == false`, an empty list, or a list with no HTTP proxy becomes `ignore`.
    public static func argument(enabled: Bool, proxies: [[String: Any]]) -> String {
        guard enabled, let uri = httpURI(in: proxies) else { return ignore }
        return uri
    }

    /// Resolves the system proxy for `host` (a gateway when one is set, otherwise the PC).
    public static func argument(enabled: Bool, for host: String) -> String {
        guard enabled else { return ignore }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ignore }
        let target = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: target), let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            return ignore
        }
        let list = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]] ?? []
        return argument(enabled: true, proxies: list)
    }

    /// Uses the system proxy when the switch is on, and bypasses it when the switch is off.
    public static func urlSession(useHTTPProxy: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        if !useHTTPProxy {
            configuration.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: configuration)
    }

    private static func httpURI(in proxies: [[String: Any]]) -> String? {
        let http = kCFProxyTypeHTTP as String
        let https = kCFProxyTypeHTTPS as String
        for proxy in proxies {
            guard let type = proxy[kCFProxyTypeKey as String] as? String, type == http || type == https else { continue }
            guard let host = hostName(proxy[kCFProxyHostNameKey as String]) else { continue }
            let port = portNumber(proxy[kCFProxyPortNumberKey as String])
            let authority = port.map { "\(host):\($0)" } ?? host
            if let user = credential(proxy[kCFProxyUsernameKey as String], allowColon: false),
               let password = credential(proxy[kCFProxyPasswordKey as String], allowColon: true) {
                return "http://\(user):\(password)@\(authority)"
            }
            return "http://\(authority)"
        }
        return nil
    }

    private static func hostName(_ value: Any?) -> String? {
        guard let host = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        guard !host.contains(":"), !host.contains("/"), !host.contains("@"), !host.contains(" ") else { return nil }
        return host
    }

    private static func portNumber(_ value: Any?) -> Int? {
        let number: Int
        if let value = value as? Int {
            number = value
        } else if let value = value as? NSNumber {
            number = value.intValue
        } else {
            return nil
        }
        guard (1...65535).contains(number) else { return nil }
        return number
    }

    /// FreeRDP splits `user:password@host` and does not decode percent-encoding.
    /// A value that would break that split is left off, and the host is still used.
    private static func credential(_ value: Any?, allowColon: Bool) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.contains("@") || text.contains("/") || text.contains(" ") { return nil }
        if !allowColon && text.contains(":") { return nil }
        return text
    }
}

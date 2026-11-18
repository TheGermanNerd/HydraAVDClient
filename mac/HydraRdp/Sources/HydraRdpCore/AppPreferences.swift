import Foundation

/// Non-secret preferences. Passwords, the Entra tokens, and the client key stay in the Keychain.
public final class AppPreferences: ObservableObject {
    public static let suiteName = "de.itprocloud.HydraRdp.preferences"
    public static let defaultPingTarget = "8.8.8.8"
    /// The feed service only answers clients that send an approved agent. This is the web client's.
    public static let defaultFeedUserAgent = "com.microsoft.rdc.html/2.0.79.2 rdhtml-sdk/2.0.4"

    private let defaults: UserDefaults

    @Published public var pingEnabled: Bool {
        didSet { defaults.set(pingEnabled, forKey: Keys.pingEnabled) }
    }

    @Published public var pingTarget: String {
        didSet { defaults.set(pingTarget, forKey: Keys.pingTarget) }
    }

    /// Empty means the system default route.
    @Published public var networkInterface: String {
        didSet { defaults.set(networkInterface, forKey: Keys.networkInterface) }
    }

    @Published public var showSensitiveData: Bool {
        didSet { defaults.set(showSensitiveData, forKey: Keys.showSensitiveData) }
    }

    @Published public var entraExpiresAt: Date? {
        didSet {
            if let entraExpiresAt {
                defaults.set(entraExpiresAt.timeIntervalSince1970, forKey: Keys.entraExpiresAt)
            } else {
                defaults.removeObject(forKey: Keys.entraExpiresAt)
            }
        }
    }

    /// Workspace resources the user has marked as favorites. Saved PCs store this on the desktop itself.
    @Published public var favoriteResourceIDs: [String] {
        didSet { defaults.set(favoriteResourceIDs, forKey: Keys.favoriteResourceIDs) }
    }

    /// An admin-provided workspace feed, loaded in addition to the discovered feeds.
    @Published public var workspaceFeedURL: String {
        didSet { defaults.set(workspaceFeedURL, forKey: Keys.workspaceFeedURL) }
    }

    /// Per-resource name, credential, and display choices for published desktops and apps.
    @Published public var publishedPCs: [PublishedPCConfiguration] {
        didSet {
            if let data = try? JSONEncoder().encode(publishedPCs) {
                defaults.set(data, forKey: Keys.publishedPCs)
            }
        }
    }

    /// Use the system HTTP proxy for workspace downloads and RD Gateway connections.
    @Published public var useHTTPProxy: Bool {
        didSet { defaults.set(useHTTPProxy, forKey: Keys.useHTTPProxy) }
    }

    /// Prefer UDP Shortpath when the server offers it.
    @Published public var useUDP: Bool {
        didSet { defaults.set(useUDP, forKey: Keys.useUDP) }
    }

    /// Optimize audio and video when the server supports Teams redirection.
    @Published public var teamsOptimizations: Bool {
        didSet { defaults.set(teamsOptimizations, forKey: Keys.teamsOptimizations) }
    }

    /// Complete in-session WebAuthn prompts with a local passkey.
    @Published public var webAuthnRedirection: Bool {
        didSet { defaults.set(webAuthnRedirection, forKey: Keys.webAuthnRedirection) }
    }

    /// Send optional diagnostics. Stored only; nothing is sent from this client.
    @Published public var shareDiagnostics: Bool {
        didSet { defaults.set(shareDiagnostics, forKey: Keys.shareDiagnostics) }
    }

    /// Version of the bundled open-source notices the user accepted. Empty means not accepted.
    @Published public var licenseAcceptedNoticesVersion: String {
        didSet { defaults.set(licenseAcceptedNoticesVersion, forKey: Keys.licenseAcceptedNoticesVersion) }
    }

    public init(defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: AppPreferences.suiteName) ?? .standard
        self.defaults = store
        if store.object(forKey: Keys.pingEnabled) == nil {
            pingEnabled = true
        } else {
            pingEnabled = store.bool(forKey: Keys.pingEnabled)
        }
        let target = store.string(forKey: Keys.pingTarget)?.trimmingCharacters(in: .whitespacesAndNewlines)
        pingTarget = (target?.isEmpty == false) ? target! : AppPreferences.defaultPingTarget
        networkInterface = store.string(forKey: Keys.networkInterface)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showSensitiveData = store.bool(forKey: Keys.showSensitiveData)
        let expiry = store.double(forKey: Keys.entraExpiresAt)
        entraExpiresAt = expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil
        favoriteResourceIDs = store.stringArray(forKey: Keys.favoriteResourceIDs) ?? []
        workspaceFeedURL = store.string(forKey: Keys.workspaceFeedURL) ?? ""
        if let data = store.data(forKey: Keys.publishedPCs),
           let decoded = try? JSONDecoder().decode([PublishedPCConfiguration].self, from: data) {
            publishedPCs = decoded
        } else {
            publishedPCs = []
        }
        useHTTPProxy = Self.storedBool(store, Keys.useHTTPProxy, default: false)
        useUDP = Self.storedBool(store, Keys.useUDP, default: true)
        teamsOptimizations = Self.storedBool(store, Keys.teamsOptimizations, default: true)
        webAuthnRedirection = Self.storedBool(store, Keys.webAuthnRedirection, default: false)
        shareDiagnostics = Self.storedBool(store, Keys.shareDiagnostics, default: false)
        licenseAcceptedNoticesVersion = store.string(forKey: Keys.licenseAcceptedNoticesVersion) ?? ""
    }

    private static func storedBool(_ store: UserDefaults, _ key: String, default defaultValue: Bool) -> Bool {
        if store.object(forKey: key) == nil { return defaultValue }
        return store.bool(forKey: key)
    }

    public func publishedPC(id: String) -> PublishedPCConfiguration? {
        publishedPCs.first { $0.id == id }
    }

    private enum Keys {
        static let pingEnabled = "pingEnabled"
        static let pingTarget = "pingTarget"
        static let networkInterface = "networkInterface"
        static let showSensitiveData = "showSensitiveData"
        static let entraExpiresAt = "entraExpiresAt"
        static let favoriteResourceIDs = "favoriteResourceIDs"
        static let workspaceFeedURL = "workspaceFeedURL"
        static let publishedPCs = "publishedPCs"
        static let useHTTPProxy = "useHTTPProxy"
        static let useUDP = "useUDP"
        static let teamsOptimizations = "teamsOptimizations"
        static let webAuthnRedirection = "webAuthnRedirection"
        static let shareDiagnostics = "shareDiagnostics"
        static let licenseAcceptedNoticesVersion = "licenseAcceptedNoticesVersion"
    }
}

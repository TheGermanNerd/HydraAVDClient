import AppKit
import AuthenticationServices
import Foundation
import HydraAgentCore
import HydraRdpCore

@MainActor
final class AppModel: ObservableObject {
    var preferences: AppPreferences
    @Published var desktops: [SavedDesktop]
    @Published var channels: [ExtraChannel]
    @Published var resources: [WorkspaceResource] = []
    @Published var workspaceName = ""
    @Published var status = ""
    @Published var clientKey = ""
    @Published var signedIn = false
    @Published var accountName = ""
    @Published var accountUsername = ""
    @Published var showingDesktopForm = false
    @Published var editingDesktop = SavedDesktop(name: "", host: "", user: "")
    @Published var desktopSignIn: DesktopSignInRequest?
    @Published var showingInstaller: Bool

    private let signIn = EntraSignIn()
    private let inventory = LiveInventory()

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        desktops = DesktopStore.load()
        channels = ExtraChannelStore.load()
        let storedKey = ClientKeyStore.load()
        clientKey = storedKey
        signedIn = EntraSecretStore.accessToken() != nil
        let notices = LicenseTexts.load()
        showingInstaller = InstallerRules.needsSetup(
            licenseAcceptedVersion: preferences.licenseAcceptedNoticesVersion,
            licenseCurrentVersion: notices.version,
            clientKey: storedKey
        )
        loadAccount()
    }

    func toggleFavorite(_ desktop: SavedDesktop) {
        guard let index = desktops.firstIndex(where: { $0.id == desktop.id }) else { return }
        desktops[index].isFavorite.toggle()
        DesktopStore.save(desktops)
    }

    func savePublishedPC(_ configuration: PublishedPCConfiguration) {
        var next = preferences.publishedPCs
        if let index = next.firstIndex(where: { $0.id == configuration.id }) {
            next[index] = configuration
        } else {
            next.append(configuration)
        }
        preferences.publishedPCs = next
    }

    func toggleFavorite(resourceID: String) {
        var ids = preferences.favoriteResourceIDs
        if let index = ids.firstIndex(of: resourceID) {
            ids.remove(at: index)
        } else {
            ids.append(resourceID)
        }
        preferences.favoriteResourceIDs = ids
    }

    func addWorkspace(urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            status = "Enter an http or https workspace URL."
            return
        }
        preferences.workspaceFeedURL = url.absoluteString
        if signedIn || EntraSecretStore.refreshToken() != nil {
            await refreshFeed()
        } else {
            status = "Sign in to load \(url.host ?? "the workspace")."
            await signIn()
        }
    }

    @discardableResult
    func saveClientKey() -> Bool {
        do {
            try ClientKeyStore.save(clientKey)
            status = clientKey.isEmpty ? "Client key removed." : "Client key saved to the Keychain."
            return true
        } catch {
            status = describe(error)
            return false
        }
    }

    func saveDesktop(_ desktop: SavedDesktop, password: String, gatewayPassword: String) {
        var next = desktops
        if let index = next.firstIndex(where: { $0.id == desktop.id }) {
            next[index] = desktop
        } else {
            next.append(desktop)
        }
        desktops = next
        DesktopStore.save(next)
        do {
            if password.isEmpty {
                KeychainStore.remove(account: DesktopSecrets.passwordAccount(desktop.id))
            } else {
                try KeychainStore.set(password, account: DesktopSecrets.passwordAccount(desktop.id))
            }
            if gatewayPassword.isEmpty {
                KeychainStore.remove(account: DesktopSecrets.gatewayPasswordAccount(desktop.id))
            } else {
                try KeychainStore.set(gatewayPassword, account: DesktopSecrets.gatewayPasswordAccount(desktop.id))
            }
            status = "Saved \(desktop.listTitle)."
        } catch {
            status = describe(error)
        }
    }

    func deleteDesktop(_ desktop: SavedDesktop) {
        desktops.removeAll { $0.id == desktop.id }
        DesktopStore.save(desktops)
        KeychainStore.remove(account: DesktopSecrets.passwordAccount(desktop.id))
        KeychainStore.remove(account: DesktopSecrets.gatewayPasswordAccount(desktop.id))
    }

    func saveChannels() {
        ExtraChannelStore.save(channels)
    }

    func signIn() async {
        do {
            let tokens = try await signIn.start(session: httpSession)
            try EntraSecretStore.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
            preferences.entraExpiresAt = tokens.expiresAt
            signedIn = true
            loadAccount()
            status = "Signed in."
            await refreshFeed()
        } catch {
            status = describe(error)
        }
    }

    func signOut() {
        EntraSecretStore.clear()
        preferences.entraExpiresAt = nil
        signedIn = false
        accountName = ""
        accountUsername = ""
        resources = []
        workspaceName = ""
        status = "Signed out."
    }

    func refreshFeed() async {
        do {
            let token = try await validAccessToken()
            loadAccount()
            let client = WorkspaceClient(userAgent: AppPreferences.defaultFeedUserAgent, session: httpSession)
            var feeds: [WorkspaceFeedItem] = []
            var discoveryError: Error?
            do {
                feeds = try await client.discover(accessToken: token)
            } catch {
                discoveryError = error
            }
            if let extra = extraFeed(), !feeds.contains(where: { $0.feedURL == extra.feedURL }) {
                feeds.append(extra)
            }
            guard !feeds.isEmpty else {
                if let discoveryError { throw discoveryError }
                resources = []
                workspaceName = ""
                status = "The workspace feed was empty."
                return
            }
            var found: [WorkspaceResource] = []
            var names: [String] = []
            var lastError: Error?
            for feed in feeds {
                do {
                    found.append(contentsOf: try await client.resources(feedURL: feed.feedURL, accessToken: token))
                    if !feed.name.isEmpty { names.append(feed.name) }
                } catch {
                    lastError = error
                }
            }
            if found.isEmpty, let lastError { throw lastError }
            resources = found
            workspaceName = names.joined(separator: ", ")
            let label = workspaceName.isEmpty ? "the workspace" : workspaceName
            status = "\(resources.count) resources in \(label)."
        } catch {
            status = describe(error)
        }
    }

    func connect(_ desktop: SavedDesktop) async {
        let user = desktop.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = KeychainStore.string(account: DesktopSecrets.passwordAccount(desktop.id))
        let passwordMissing = password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        if user.isEmpty || passwordMissing {
            status = "Checking \(desktop.listTitle)."
            if await RdpSecurityProbe.requiresNetworkLevelAuthentication(host: desktop.host) == true {
                desktopSignIn = DesktopSignInRequest(desktop: desktop, user: user)
                status = "\(desktop.listTitle) requires a user name and password."
                return
            }
        }
        open(desktop, user: user, password: password)
    }

    func connect(_ desktop: SavedDesktop, user: String, password: String, remember: Bool) {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !password.isEmpty else {
            status = "Enter a user name and password."
            return
        }
        desktopSignIn = nil
        var next = desktop
        next.user = trimmedUser
        if remember {
            let gateway = KeychainStore.string(account: DesktopSecrets.gatewayPasswordAccount(desktop.id)) ?? ""
            saveDesktop(next, password: password, gatewayPassword: gateway)
        }
        open(next, user: trimmedUser, password: password)
    }

    private func open(_ desktop: SavedDesktop, user: String, password: String?) {
        let launch = FreeRdpLaunchBuilder.direct(
            host: desktop.host,
            user: user,
            password: password,
            gatewayHost: desktop.gatewayHost,
            gatewayUser: desktop.gatewayUser,
            gatewayPassword: KeychainStore.string(account: DesktopSecrets.gatewayPasswordAccount(desktop.id)),
            width: desktop.displayMode == .fullscreen ? screenSize.width : 1280,
            height: desktop.displayMode == .fullscreen ? screenSize.height : 720,
            extraChannelNames: extraNames,
            connection: connection(for: proxyHost(gateway: desktop.gatewayHost, host: desktop.host))
        )
        open(title: desktop.listTitle, launch: launch, fullscreen: desktop.displayMode == .fullscreen)
    }

    func connect(_ resource: WorkspaceResource) async {
        do {
            let token = try await validAccessToken()
            let client = WorkspaceClient(userAgent: AppPreferences.defaultFeedUserAgent, session: httpSession)
            let text = try await client.rdpText(for: resource, accessToken: token)
            var file = RdpFileParser.parse(text)
            let settings = preferences.publishedPC(id: resource.id)
            if settings?.credentials == .signedInAccount, file.username == nil {
                let account = accountUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                if !account.isEmpty { file.username = account }
            }
            let custom = settings?.useCustomSettings == true
            let fullscreen = custom && settings?.displayMode == .fullscreen
            let size: (width: Int, height: Int)
            if custom {
                size = fullscreen ? screenSize : (1280, 720)
                file.desktopWidth = size.width
                file.desktopHeight = size.height
            } else {
                size = file.remoteApplicationMode ? (1280, 720) : screenSize
            }
            let launch = FreeRdpLaunchBuilder.workspace(
                file: file,
                rdpText: text,
                accessToken: token,
                refreshToken: EntraSecretStore.refreshToken(),
                width: size.width,
                height: size.height,
                extraChannelNames: extraNames,
                connection: connection(for: file.gatewayHostname ?? file.fullAddress ?? "")
            )
            let title = settings?.resolvedName(fallback: resource.name) ?? resource.name
            open(title: title, launch: launch, fullscreen: fullscreen)
        } catch {
            status = describe(error)
        }
    }

    private func open(title: String, launch: FreeRdpLaunch, fullscreen: Bool) {
        inventory.configure(
            pingEnabled: preferences.pingEnabled,
            pingTarget: preferences.pingTarget,
            networkInterface: preferences.networkInterface,
            showSensitiveData: preferences.showSensitiveData
        )
        let session = LiveSession(
            title: title,
            fullscreen: fullscreen,
            channel: HydraChannelClient(clientKey: clientKey, inventory: inventory, log: SessionChannelLog())
        )
        SessionPresenter.open(session: session, launch: launch, extraChannels: extraChannelText)
        status = "Opening \(title)."
    }

    private var extraNames: [String] {
        channels.filter(\.isUsable).map(\.name)
    }

    private var extraChannelText: String {
        channels.filter(\.isUsable).map { channel in
            switch channel.kind {
            case .echo:
                return "echo\t\(channel.name)"
            case .library:
                return "library\t\(channel.name)\t\(channel.libraryPath)"
            }
        }.joined(separator: "\n")
    }

    private var httpSession: URLSession {
        GatewayProxy.urlSession(useHTTPProxy: preferences.useHTTPProxy)
    }

    private func connection(for host: String) -> SessionConnection {
        SessionConnection(
            useUDP: preferences.useUDP,
            proxyArgument: GatewayProxy.argument(enabled: preferences.useHTTPProxy, for: host)
        )
    }

    private func proxyHost(gateway: String, host: String) -> String {
        let gateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        return gateway.isEmpty ? host : gateway
    }

    private var screenSize: (width: Int, height: Int) {
        guard let screen = NSScreen.main else { return (1280, 720) }
        let scale = screen.backingScaleFactor
        return (
            Int((screen.visibleFrame.width * scale).rounded()),
            Int((screen.visibleFrame.height * scale).rounded())
        )
    }

    private func validAccessToken() async throws -> String {
        if let token = EntraSecretStore.accessToken(),
           let expiry = preferences.entraExpiresAt,
           !EntraTokenSet(accessToken: token, refreshToken: nil, expiresAt: expiry).needsRefresh() {
            return token
        }
        guard let refresh = EntraSecretStore.refreshToken() else {
            throw EntraOAuthError("Sign in to the workspace first.")
        }
        let tokens = try await EntraOAuth.refresh(refreshToken: refresh, session: httpSession)
        try EntraSecretStore.save(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? refresh
        )
        preferences.entraExpiresAt = tokens.expiresAt
        signedIn = true
        loadAccount()
        return tokens.accessToken
    }

    private func extraFeed() -> WorkspaceFeedItem? {
        let trimmed = preferences.workspaceFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return nil }
        return WorkspaceFeedItem(id: url.absoluteString, name: url.host ?? "Workspace", feedURL: url)
    }

    private func loadAccount() {
        guard let token = EntraSecretStore.accessToken(), let profile = EntraIdentity.profile(accessToken: token) else {
            accountName = ""
            accountUsername = ""
            return
        }
        accountName = profile.name
        accountUsername = profile.username
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? EntraOAuthError { return error.description }
        if let error = error as? WorkspaceClientError { return error.description }
        if let error = error as? KeychainError { return error.description }
        return error.localizedDescription
    }
}

@MainActor
final class EntraSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func start(session urlSession: URLSession = .shared) async throws -> EntraTokenSet {
        let authorization = try EntraOAuth.start()
        let scheme = URL(string: authorization.redirectURI)?.scheme
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorization.url,
                callbackURLScheme: scheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: EntraOAuthError("Sign-in was cancelled."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: EntraOAuthError("Could not open the sign-in browser."))
            }
        }
        let code = try EntraOAuth.code(from: callback, expectedState: authorization.state)
        return try await EntraOAuth.exchange(authorization: authorization, code: code, session: urlSession)
    }
}

final class LiveInventory: InventoryProviding {
    private let collector = MacSnapshotCollector()
    private let performance = PerformanceMonitor()
    private var pingEnabled = true
    private var pingTarget = AppPreferences.defaultPingTarget
    private var networkInterface = ""
    private var showSensitiveData = false

    init() {
        performance.start()
    }

    func configure(pingEnabled: Bool, pingTarget: String, networkInterface: String, showSensitiveData: Bool) {
        self.pingEnabled = pingEnabled
        let trimmed = pingTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pingTarget = trimmed.isEmpty ? AppPreferences.defaultPingTarget : trimmed
        self.networkInterface = networkInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        self.showSensitiveData = showSensitiveData
        performance.setNetworkInterface(self.networkInterface)
    }

    func performanceJSON() async -> String {
        let snapshot = await loadSnapshot()
        return performance.record(snapshot: snapshot)
    }

    func loadSnapshot() async -> ClientSnapshot {
        let displays = await MainActor.run { () -> [DisplayInfo] in
            NSScreen.screens.map { screen in
                let scale = screen.backingScaleFactor
                return DisplayInfo(
                    width: Int((screen.frame.width * scale).rounded()),
                    height: Int((screen.frame.height * scale).rounded()),
                    scaleFactor: scale
                )
            }
        }
        return await collector.makeSnapshot(
            pingEnabled: pingEnabled,
            pingTarget: pingTarget,
            networkInterface: networkInterface,
            showSensitiveData: showSensitiveData,
            displays: displays
        )
    }

    func cpuPercent() -> Double {
        CpuMeter.percent()
    }
}

final class SessionChannelLog: ChannelLog {
    func info(_ message: String) {
        NSLog("Hydra channel: %@", message)
    }

    func error(_ message: String) {
        NSLog("Hydra channel error: %@", message)
    }
}

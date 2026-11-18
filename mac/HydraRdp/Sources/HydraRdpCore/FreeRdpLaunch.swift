import Foundation
import HydraChannelProtocol

/// FreeRDP command line for one session. The desktop password, gateway password, and tokens stay off `arguments`.
/// A system HTTP proxy login is the exception: FreeRDP only accepts it inside `/proxy`.
public struct FreeRdpLaunch: Equatable {
    public var arguments: [String]
    public var rdpText: String?
    public var password: String?
    public var gatewayPassword: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var armGateway: Bool
    public var entraAuth: Bool
    public var remoteApp: Bool
    public var loadBalanceInfo: String?
    public var width: Int
    public var height: Int

    public init(
        arguments: [String],
        rdpText: String? = nil,
        password: String? = nil,
        gatewayPassword: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        armGateway: Bool = false,
        entraAuth: Bool = false,
        remoteApp: Bool = false,
        loadBalanceInfo: String? = nil,
        width: Int,
        height: Int
    ) {
        self.arguments = arguments
        self.rdpText = rdpText
        self.password = password
        self.gatewayPassword = gatewayPassword
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.armGateway = armGateway
        self.entraAuth = entraAuth
        self.remoteApp = remoteApp
        self.loadBalanceInfo = loadBalanceInfo
        self.width = width
        self.height = height
    }
}

public enum FreeRdpLaunchBuilder {
    public static func direct(
        host: String,
        user: String,
        password: String?,
        gatewayHost: String?,
        gatewayUser: String?,
        gatewayPassword: String?,
        width: Int,
        height: Int,
        extraChannelNames: [String] = [],
        connection: SessionConnection = .windowsAppDefaults
    ) -> FreeRdpLaunch {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let pixelWidth = positive(width) ?? 1280
        let pixelHeight = positive(height) ?? 720
        var arguments = ["HydraRdp", "/v:\(target)"]
        appendUser(&arguments, user)
        if let gatewayHost, !gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append("/gateway:g:\(gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)),type:auto")
            if let gatewayUser {
                let trimmed = gatewayUser.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    arguments.append("/gu:\(trimmed)")
                }
            }
        }
        appendSessionFlags(
            &arguments,
            width: pixelWidth,
            height: pixelHeight,
            extraChannelNames: extraChannelNames,
            connection: connection
        )
        return FreeRdpLaunch(
            arguments: arguments,
            password: blankToNil(password),
            gatewayPassword: blankToNil(gatewayPassword),
            width: pixelWidth,
            height: pixelHeight
        )
    }

    public static func workspace(
        file: ParsedRdpFile,
        rdpText: String,
        accessToken: String?,
        refreshToken: String? = nil,
        width: Int,
        height: Int,
        extraChannelNames: [String] = [],
        connection: SessionConnection = .windowsAppDefaults
    ) -> FreeRdpLaunch {
        let pixelWidth = positive(file.desktopWidth) ?? positive(width) ?? 1280
        let pixelHeight = positive(file.desktopHeight) ?? positive(height) ?? 720
        var arguments = ["HydraRdp"]
        if let host = file.fullAddress {
            arguments.append("/v:\(host)")
        }
        if let user = file.username {
            arguments.append("/u:\(user)")
        }
        if let domain = file.domain {
            arguments.append("/d:\(domain)")
        }
        if file.usesArmGateway || file.gatewayHostname != nil {
            var gateway = "/gateway:type:arm"
            if let host = file.gatewayHostname {
                gateway += ",g:\(host)"
            }
            arguments.append(gateway)
        }
        if file.usesEntraAuth {
            arguments.append("/sec:aad")
        }
        if let info = file.loadBalanceInfo {
            arguments.append("/load-balance-info:\(info)")
        }
        if let tenant = file.aadTenantId {
            arguments.append("/azure:tenantid:\(tenant)")
        }
        let remoteApp = file.remoteApplicationMode && file.remoteApplicationProgram != nil
        if remoteApp, let program = file.remoteApplicationProgram {
            var option = "/app:program:\(program)"
            if let name = file.remoteApplicationName {
                option += ",name:\(name)"
            }
            if let command = file.remoteApplicationCommandLine {
                option += ",cmd:\(command)"
            }
            arguments.append(option)
        }
        appendSessionFlags(
            &arguments,
            width: pixelWidth,
            height: pixelHeight,
            extraChannelNames: extraChannelNames,
            connection: connection
        )
        let token = blankToNil(accessToken) ?? file.gatewayAccessToken
        return FreeRdpLaunch(
            arguments: arguments,
            rdpText: rdpText,
            password: file.password,
            accessToken: token,
            refreshToken: blankToNil(refreshToken),
            armGateway: file.usesArmGateway,
            entraAuth: file.usesEntraAuth,
            remoteApp: remoteApp,
            loadBalanceInfo: file.loadBalanceInfo,
            width: pixelWidth,
            height: pixelHeight
        )
    }

    private static func appendUser(_ arguments: inout [String], _ user: String) {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let slash = trimmed.firstIndex(of: "\\") {
            let domain = String(trimmed[..<slash])
            let name = String(trimmed[trimmed.index(after: slash)...])
            if !domain.isEmpty { arguments.append("/d:\(domain)") }
            if !name.isEmpty { arguments.append("/u:\(name)") }
        } else {
            arguments.append("/u:\(trimmed)")
        }
    }

    private static func appendSessionFlags(
        _ arguments: inout [String],
        width: Int,
        height: Int,
        extraChannelNames: [String],
        connection: SessionConnection
    ) {
        arguments.append("/w:\(width)")
        arguments.append("/h:\(height)")
        arguments.append("/dynamic-resolution")
        arguments.append("+clipboard")
        arguments.append("/gfx:AVC444")
        arguments.append("/cert:ignore")
        arguments.append(connection.useUDP ? "/multitransport:udp" : "/multitransport:tcp-only")
        arguments.append("/proxy:\(connection.proxyArgument)")
        arguments.append("/dvc:\(HydraChannelProtocol.channelName)")
        for name in extraChannelNames where ExtraChannel.isValidName(name) {
            arguments.append("/dvc:\(name)")
        }
    }

    /// AVD publishes `desktopwidth:i:0` when the client should choose the size.
    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

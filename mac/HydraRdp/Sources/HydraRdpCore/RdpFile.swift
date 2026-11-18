import Foundation

public enum RdpValue: Equatable {
    case string(String)
    case integer(Int)
}

public struct ParsedRdpFile: Equatable {
    public var entries: [String: RdpValue]
    public var fullAddress: String?
    public var username: String?
    public var domain: String?
    public var gatewayHostname: String?
    public var loadBalanceInfo: String?
    public var gatewayAccessToken: String?
    public var password: String?
    public var enableRdsAadAuth: Bool
    public var resourceProvider: String?
    public var remoteApplicationMode: Bool
    public var remoteApplicationProgram: String?
    public var remoteApplicationName: String?
    public var remoteApplicationCommandLine: String?
    public var desktopWidth: Int?
    public var desktopHeight: Int?
    public var armPath: String?
    public var aadTenantId: String?
    public var wvdEndpointPool: String?
    public var geo: String?

    public var usesArmGateway: Bool {
        resourceProvider?.caseInsensitiveCompare("arm") == .orderedSame
    }

    public var usesEntraAuth: Bool {
        enableRdsAadAuth
    }

    public init(
        entries: [String: RdpValue] = [:],
        fullAddress: String? = nil,
        username: String? = nil,
        domain: String? = nil,
        gatewayHostname: String? = nil,
        loadBalanceInfo: String? = nil,
        gatewayAccessToken: String? = nil,
        password: String? = nil,
        enableRdsAadAuth: Bool = false,
        resourceProvider: String? = nil,
        remoteApplicationMode: Bool = false,
        remoteApplicationProgram: String? = nil,
        remoteApplicationName: String? = nil,
        remoteApplicationCommandLine: String? = nil,
        desktopWidth: Int? = nil,
        desktopHeight: Int? = nil,
        armPath: String? = nil,
        aadTenantId: String? = nil,
        wvdEndpointPool: String? = nil,
        geo: String? = nil
    ) {
        self.entries = entries
        self.fullAddress = fullAddress
        self.username = username
        self.domain = domain
        self.gatewayHostname = gatewayHostname
        self.loadBalanceInfo = loadBalanceInfo
        self.gatewayAccessToken = gatewayAccessToken
        self.password = password
        self.enableRdsAadAuth = enableRdsAadAuth
        self.resourceProvider = resourceProvider
        self.remoteApplicationMode = remoteApplicationMode
        self.remoteApplicationProgram = remoteApplicationProgram
        self.remoteApplicationName = remoteApplicationName
        self.remoteApplicationCommandLine = remoteApplicationCommandLine
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.armPath = armPath
        self.aadTenantId = aadTenantId
        self.wvdEndpointPool = wvdEndpointPool
        self.geo = geo
    }
}

public enum RdpFileParser {
    public static func parse(_ text: String) -> ParsedRdpFile {
        var entries: [String: RdpValue] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            guard let parsed = parseLine(line) else { continue }
            entries[parsed.key] = parsed.value
        }

        func string(_ key: String) -> String? {
            if case let .string(value) = entries[key] {
                return value
            }
            return nil
        }
        func integer(_ key: String) -> Int? {
            if case let .integer(value) = entries[key] { return value }
            if case let .string(value) = entries[key] { return Int(value) }
            return nil
        }

        let username = string("username")
        let explicitDomain = string("domain")
        let split = splitUser(username)

        return ParsedRdpFile(
            entries: entries,
            fullAddress: blankToNil(string("full address")),
            username: blankToNil(split.user ?? username),
            domain: blankToNil(explicitDomain) ?? blankToNil(split.domain),
            gatewayHostname: blankToNil(string("gatewayhostname")),
            loadBalanceInfo: blankToNil(string("loadbalanceinfo")),
            gatewayAccessToken: blankToNil(string("gatewayaccesstoken")),
            password: blankToNil(string("password")),
            enableRdsAadAuth: integer("enablerdsaadauth") == 1,
            resourceProvider: blankToNil(string("resourceprovider")),
            remoteApplicationMode: integer("remoteapplicationmode") == 1,
            remoteApplicationProgram: blankToNil(string("remoteapplicationprogram")),
            remoteApplicationName: blankToNil(string("remoteapplicationname")),
            remoteApplicationCommandLine: blankToNil(string("remoteapplicationcmdline")),
            desktopWidth: integer("desktopwidth"),
            desktopHeight: integer("desktopheight"),
            armPath: blankToNil(string("armpath")),
            aadTenantId: blankToNil(string("aadtenantid")),
            wvdEndpointPool: blankToNil(string("wvd endpoint pool")),
            geo: blankToNil(string("geo"))
        )
    }

    private static func parseLine(_ line: String) -> (key: String, value: RdpValue)? {
        guard let first = line.firstIndex(of: ":") else { return nil }
        let key = line[..<first].trimmingCharacters(in: .whitespaces).lowercased()
        let rest = line[line.index(after: first)...]
        guard let second = rest.firstIndex(of: ":") else { return nil }
        let type = rest[..<second].trimmingCharacters(in: .whitespaces).lowercased()
        let raw = String(rest[rest.index(after: second)...])
        guard !key.isEmpty, type.count == 1 else { return nil }
        switch type {
        case "i":
            return (key, .integer(Int(raw.trimmingCharacters(in: .whitespaces)) ?? 0))
        case "s", "b":
            return (key, .string(raw))
        default:
            return nil
        }
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func splitUser(_ username: String?) -> (domain: String?, user: String?) {
        guard let username, let slash = username.firstIndex(of: "\\") else {
            return (nil, username)
        }
        let domain = String(username[..<slash])
        let user = String(username[username.index(after: slash)...])
        return (domain, user)
    }
}

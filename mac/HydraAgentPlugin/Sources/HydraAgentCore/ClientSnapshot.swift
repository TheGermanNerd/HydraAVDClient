import Foundation

public struct ClientSnapshot: Encodable, Equatable {
    public var schemaVersion: Int
    public var collectorName: String
    public var collectedAtUtc: Date
    public var device: DeviceSection?
    public var software: SoftwareSection?
    public var network: NetworkSection?
    public var security: SecuritySection?
    public var sensitive: SensitiveSection?
    public var errors: [String]?

    public static let currentSchemaVersion = 1
    public static let macCollectorName = "HydraAgentMac"

    public init(
        schemaVersion: Int = ClientSnapshot.currentSchemaVersion,
        collectorName: String = ClientSnapshot.macCollectorName,
        collectedAtUtc: Date,
        device: DeviceSection? = nil,
        software: SoftwareSection? = nil,
        network: NetworkSection? = nil,
        security: SecuritySection? = nil,
        sensitive: SensitiveSection? = nil,
        errors: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.collectorName = collectorName
        self.collectedAtUtc = collectedAtUtc
        self.device = device
        self.software = software
        self.network = network
        self.security = security
        self.sensitive = sensitive
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case collectorName
        case collectedAtUtc
        case device
        case software
        case network
        case security
        case sensitive
        case errors
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(collectorName, forKey: .collectorName)
        try container.encode(collectedAtUtc, forKey: .collectedAtUtc)
        try container.encodeIfPresent(device, forKey: .device)
        try container.encodeIfPresent(software, forKey: .software)
        try container.encodeIfPresent(network, forKey: .network)
        try container.encodeIfPresent(security, forKey: .security)
        try container.encodeIfPresent(sensitive, forKey: .sensitive)
        try container.encodeIfPresent(errors, forKey: .errors)
    }
}

public enum SnapshotAssembly {
    /// Drops the sensitive section unless the user has opted in, and drops an empty error list.
    public static func make(
        collectedAtUtc: Date,
        device: DeviceSection?,
        software: SoftwareSection?,
        network: NetworkSection?,
        security: SecuritySection?,
        sensitive: SensitiveSection?,
        errors: [String],
        showSensitiveData: Bool
    ) -> ClientSnapshot {
        let securitySection = security?.isEmpty == true ? nil : security
        return ClientSnapshot(
            collectedAtUtc: collectedAtUtc,
            device: device,
            software: software,
            network: network,
            security: securitySection,
            sensitive: showSensitiveData ? sensitive : nil,
            errors: errors.isEmpty ? nil : errors
        )
    }
}

public struct DeviceSection: Encodable, Equatable {
    public var productName: String
    public var productVersion: String
    public var buildVersion: String
    public var hardwareModel: String
    public var cpuBrand: String
    public var cpuCount: Int
    public var memoryBytes: Int64
    public var disks: [DiskInfo]
    public var gpus: [String]
    public var displays: [DisplayInfo]
    public var battery: BatteryInfo

    public init(
        productName: String,
        productVersion: String,
        buildVersion: String,
        hardwareModel: String,
        cpuBrand: String,
        cpuCount: Int,
        memoryBytes: Int64,
        disks: [DiskInfo],
        gpus: [String],
        displays: [DisplayInfo],
        battery: BatteryInfo
    ) {
        self.productName = productName
        self.productVersion = productVersion
        self.buildVersion = buildVersion
        self.hardwareModel = hardwareModel
        self.cpuBrand = cpuBrand
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.disks = disks
        self.gpus = gpus
        self.displays = displays
        self.battery = battery
    }
}

public struct DiskInfo: Encodable, Equatable {
    public var mountPoint: String
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var fileSystem: String?

    public init(mountPoint: String, totalBytes: Int64, availableBytes: Int64, fileSystem: String?) {
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.fileSystem = fileSystem
    }

    enum CodingKeys: String, CodingKey {
        case mountPoint
        case totalBytes
        case availableBytes
        case fileSystem
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mountPoint, forKey: .mountPoint)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encode(availableBytes, forKey: .availableBytes)
        try container.encodeIfPresent(fileSystem, forKey: .fileSystem)
    }
}

public struct DisplayInfo: Encodable, Equatable {
    public var width: Int
    public var height: Int
    public var scaleFactor: Double

    public init(width: Int, height: Int, scaleFactor: Double) {
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
    }
}

public struct BatteryInfo: Encodable, Equatable {
    public var present: Bool
    public var chargePercentage: Int?
    public var isCharging: Bool?

    public init(present: Bool, chargePercentage: Int?, isCharging: Bool?) {
        self.present = present
        self.chargePercentage = chargePercentage
        self.isCharging = isCharging
    }

    enum CodingKeys: String, CodingKey {
        case present
        case chargePercentage
        case isCharging
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(present, forKey: .present)
        try container.encodeIfPresent(chargePercentage, forKey: .chargePercentage)
        try container.encodeIfPresent(isCharging, forKey: .isCharging)
    }
}

public struct SoftwareSection: Encodable, Equatable {
    public var applications: [ApplicationInfo]

    public init(applications: [ApplicationInfo]) {
        self.applications = applications
    }
}

public struct ApplicationInfo: Encodable, Equatable {
    public var name: String
    public var version: String?

    public init(name: String, version: String?) {
        self.name = name
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case name
        case version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(version, forKey: .version)
    }
}

public struct NetworkSection: Encodable, Equatable {
    public var interfaces: [InterfaceInfo]
    public var gateway: GatewayInfo?
    public var internetPing: PingSample?
    public var gatewayPing: PingSample?
    public var publicIp: String?
    /// BSD name the gateway, public IP, and pings were bound to. Omitted when collection follows the default route.
    public var boundInterface: String?

    public init(
        interfaces: [InterfaceInfo],
        gateway: GatewayInfo?,
        internetPing: PingSample?,
        gatewayPing: PingSample?,
        publicIp: String?,
        boundInterface: String? = nil
    ) {
        self.interfaces = interfaces
        self.gateway = gateway
        self.internetPing = internetPing
        self.gatewayPing = gatewayPing
        self.publicIp = publicIp
        self.boundInterface = boundInterface
    }

    enum CodingKeys: String, CodingKey {
        case interfaces
        case gateway
        case internetPing
        case gatewayPing
        case publicIp
        case boundInterface
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interfaces, forKey: .interfaces)
        try container.encodeIfPresent(gateway, forKey: .gateway)
        try container.encodeIfPresent(internetPing, forKey: .internetPing)
        try container.encodeIfPresent(gatewayPing, forKey: .gatewayPing)
        try container.encodeIfPresent(publicIp, forKey: .publicIp)
        try container.encodeIfPresent(boundInterface, forKey: .boundInterface)
    }
}

public struct InterfaceInfo: Encodable, Equatable {
    public var name: String
    public var address: String
    public var family: String

    public init(name: String, address: String, family: String) {
        self.name = name
        self.address = address
        self.family = family
    }
}

public struct GatewayInfo: Encodable, Equatable {
    public var address: String
    public var interfaceName: String?

    public init(address: String, interfaceName: String?) {
        self.address = address
        self.interfaceName = interfaceName
    }

    enum CodingKeys: String, CodingKey {
        case address
        case interfaceName = "interface"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        try container.encodeIfPresent(interfaceName, forKey: .interfaceName)
    }
}

public struct PingSample: Encodable, Equatable {
    public var target: String
    public var reachable: Bool
    public var latencyMs: Double?
    public var skipped: Bool

    public init(target: String, reachable: Bool, latencyMs: Double?, skipped: Bool) {
        self.target = target
        self.reachable = reachable
        self.latencyMs = latencyMs
        self.skipped = skipped
    }

    enum CodingKeys: String, CodingKey {
        case target
        case reachable
        case latencyMs
        case skipped
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(reachable, forKey: .reachable)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encode(skipped, forKey: .skipped)
    }
}

public struct SecuritySection: Encodable, Equatable {
    public var fileVaultEnabled: Bool?
    public var firewallEnabled: Bool?

    public init(fileVaultEnabled: Bool?, firewallEnabled: Bool?) {
        self.fileVaultEnabled = fileVaultEnabled
        self.firewallEnabled = firewallEnabled
    }

    public var isEmpty: Bool {
        fileVaultEnabled == nil && firewallEnabled == nil
    }

    enum CodingKeys: String, CodingKey {
        case fileVaultEnabled
        case firewallEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fileVaultEnabled, forKey: .fileVaultEnabled)
        try container.encodeIfPresent(firewallEnabled, forKey: .firewallEnabled)
    }
}

public struct SensitiveSection: Encodable, Equatable {
    public var userName: String?
    public var computerName: String?
    public var serialNumber: String?
    public var wifiSsid: String?
    public var location: LocationFix?

    public init(
        userName: String?,
        computerName: String?,
        serialNumber: String?,
        wifiSsid: String?,
        location: LocationFix?
    ) {
        self.userName = userName
        self.computerName = computerName
        self.serialNumber = serialNumber
        self.wifiSsid = wifiSsid
        self.location = location
    }

    enum CodingKeys: String, CodingKey {
        case userName
        case computerName
        case serialNumber
        case wifiSsid
        case location
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(userName, forKey: .userName)
        try container.encodeIfPresent(computerName, forKey: .computerName)
        try container.encodeIfPresent(serialNumber, forKey: .serialNumber)
        try container.encodeIfPresent(wifiSsid, forKey: .wifiSsid)
        try container.encodeIfPresent(location, forKey: .location)
    }
}

public struct LocationFix: Encodable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum SnapshotEncoder {
    public static func encode(_ snapshot: ClientSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
}

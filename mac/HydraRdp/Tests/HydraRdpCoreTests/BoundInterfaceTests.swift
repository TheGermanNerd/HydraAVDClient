import Foundation
import HydraAgentCore
import Testing
@testable import HydraRdpCore

@Test func boundInterfaceBecomesTheActiveConnectionAndPrimaryAddress() throws {
    let snapshot = ClientSnapshot(
        collectedAtUtc: Date(timeIntervalSince1970: 1_700_000_000),
        device: DeviceSection(
            productName: "macOS",
            productVersion: "15.1",
            buildVersion: "24B83",
            hardwareModel: "Mac14,1",
            cpuBrand: "Apple M2",
            cpuCount: 8,
            memoryBytes: 16_000_000_000,
            disks: [],
            gpus: [],
            displays: [],
            battery: BatteryInfo(present: false, chargePercentage: nil, isCharging: nil)
        ),
        network: NetworkSection(
            interfaces: [
                InterfaceInfo(name: "en0", address: "10.1.2.3", family: "ipv4"),
                InterfaceInfo(name: "en1", address: "192.168.5.9", family: "ipv4")
            ],
            gateway: GatewayInfo(address: "192.168.5.1", interfaceName: "en1"),
            internetPing: nil,
            gatewayPing: nil,
            publicIp: nil,
            boundInterface: "en1"
        )
    )

    let network = try jsonObject(EndpointInventory.network(snapshot, parameter: ""))
    let active = try section(network, "ActiveConnection")
    #expect(active["InterfaceName"] as? String == "en1")
    #expect(active["IPv4Address"] as? String == "192.168.5.9")
    #expect(active["Gateway"] as? String == "192.168.5.1")

    let inventory = try jsonObject(EndpointInventory.systemInventory(snapshot, cpuPercent: 0))
    let operatingSystem = try section(inventory, "OperatingSystem")
    #expect(operatingSystem["PrimaryIPv4Address"] as? String == "192.168.5.9")
}

private func jsonObject(_ payload: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
}

private func section(_ object: [String: Any], _ name: String) throws -> [String: Any] {
    let wrapped = try #require(object[name] as? [String: Any])
    #expect(wrapped["IsAvailable"] as? Bool == true)
    return try #require(wrapped["Value"] as? [String: Any])
}

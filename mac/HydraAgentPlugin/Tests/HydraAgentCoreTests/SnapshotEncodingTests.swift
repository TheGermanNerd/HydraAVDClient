import Foundation
import Testing
@testable import HydraAgentCore

private let collectedAt = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!

private func sensitiveSample() -> SensitiveSection {
    SensitiveSection(
        userName: "ada",
        computerName: "Ada's Mac",
        serialNumber: "C02SECRET",
        wifiSsid: "OfficeWiFi",
        location: LocationFix(latitude: 52.52, longitude: 13.405)
    )
}

@Test func sensitiveFieldsAreOmittedByDefault() throws {
    let snapshot = SnapshotAssembly.make(
        collectedAtUtc: collectedAt,
        device: nil,
        software: nil,
        network: nil,
        security: nil,
        sensitive: sensitiveSample(),
        errors: [],
        showSensitiveData: false
    )
    let json = try encodedString(snapshot)
    #expect(!json.contains("\"sensitive\""))
    #expect(!json.contains("ada"))
    #expect(!json.contains("OfficeWiFi"))
    #expect(!json.contains("C02SECRET"))
    #expect(!json.contains("52.52"))
    #expect(!json.contains("\"errors\""))
    #expect(json.contains("\"schemaVersion\" : 1"))
    #expect(json.contains("\"collectorName\" : \"HydraAgentMac\""))
    #expect(json.contains("2026-11-17T12:00:00Z"))
}

@Test func sensitiveFieldsAreIncludedWhenEnabled() throws {
    let snapshot = SnapshotAssembly.make(
        collectedAtUtc: collectedAt,
        device: nil,
        software: nil,
        network: nil,
        security: SecuritySection(fileVaultEnabled: true, firewallEnabled: false),
        sensitive: sensitiveSample(),
        errors: ["public IP lookup failed"],
        showSensitiveData: true
    )
    let object = try jsonObject(snapshot)
    let sensitive = object["sensitive"] as? [String: Any]
    #expect(sensitive?["userName"] as? String == "ada")
    #expect(sensitive?["computerName"] as? String == "Ada's Mac")
    #expect(sensitive?["serialNumber"] as? String == "C02SECRET")
    #expect(sensitive?["wifiSsid"] as? String == "OfficeWiFi")
    let location = sensitive?["location"] as? [String: Any]
    #expect(location?["latitude"] as? Double == 52.52)
    #expect(location?["longitude"] as? Double == 13.405)

    let security = object["security"] as? [String: Any]
    #expect(security?["fileVaultEnabled"] as? Bool == true)
    #expect(security?["firewallEnabled"] as? Bool == false)
    #expect(object["errors"] as? [String] == ["public IP lookup failed"])
}

@Test func partialSensitiveSectionOmitsMissingValues() throws {
    let snapshot = SnapshotAssembly.make(
        collectedAtUtc: collectedAt,
        device: nil,
        software: nil,
        network: NetworkSection(
            interfaces: [InterfaceInfo(name: "en0", address: "10.0.0.5", family: "ipv4")],
            gateway: GatewayInfo(address: "10.0.0.1", interfaceName: "en0"),
            internetPing: PingSample(target: "8.8.8.8", reachable: false, latencyMs: nil, skipped: true),
            gatewayPing: nil,
            publicIp: nil
        ),
        security: nil,
        sensitive: SensitiveSection(
            userName: "ada",
            computerName: nil,
            serialNumber: nil,
            wifiSsid: nil,
            location: nil
        ),
        errors: [],
        showSensitiveData: true
    )
    let object = try jsonObject(snapshot)
    let sensitive = object["sensitive"] as? [String: Any]
    #expect(sensitive?["userName"] as? String == "ada")
    #expect(sensitive?["wifiSsid"] == nil)
    #expect(sensitive?["location"] == nil)
    #expect(sensitive?["serialNumber"] == nil)

    let network = object["network"] as? [String: Any]
    let ping = network?["internetPing"] as? [String: Any]
    #expect(ping?["skipped"] as? Bool == true)
    #expect(ping?["latencyMs"] == nil)
    #expect(network?["publicIp"] == nil)
    #expect(network?["gatewayPing"] == nil)
    let gateway = network?["gateway"] as? [String: Any]
    #expect(gateway?["interface"] as? String == "en0")
}

@Test func emptySecuritySectionIsOmitted() throws {
    let snapshot = SnapshotAssembly.make(
        collectedAtUtc: collectedAt,
        device: nil,
        software: nil,
        network: nil,
        security: SecuritySection(fileVaultEnabled: nil, firewallEnabled: nil),
        sensitive: nil,
        errors: [],
        showSensitiveData: false
    )
    let object = try jsonObject(snapshot)
    #expect(object["security"] == nil)
    #expect(object["sensitive"] == nil)
}

private func encodedString(_ snapshot: ClientSnapshot) throws -> String {
    let data = try SnapshotEncoder.encode(snapshot)
    return String(data: data, encoding: .utf8) ?? ""
}

private func jsonObject(_ snapshot: ClientSnapshot) throws -> [String: Any] {
    let data = try SnapshotEncoder.encode(snapshot)
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}

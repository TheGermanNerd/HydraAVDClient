import Foundation
import HydraAgentCore
import HydraChannelProtocol
import Testing
@testable import HydraRdpCore

private let clientKey = "client-key-DO-NOT-LEAK-91f7"

private final class FakeInventory: InventoryProviding {
    func loadSnapshot() async -> ClientSnapshot {
        ClientSnapshot(
            collectedAtUtc: Date(timeIntervalSince1970: 1_700_000_000),
            errors: ["snapshot-marker"]
        )
    }

    func cpuPercent() -> Double { 12.5 }
}

private func client(log: MemoryChannelLog) -> HydraChannelClient {
    HydraChannelClient(clientKey: clientKey, inventory: FakeInventory(), log: log, trace: { _, _ in nil })
}

private func frame(_ type: HydraChannelProtocol.MessageType, _ sequence: UInt32, _ payload: String) -> Data {
    HydraChannelProtocol.Frame(messageType: type, sequence: sequence, payload: payload).encoded()
}

private func writtenFrame(_ events: [ChannelEvent]) throws -> HydraChannelProtocol.Frame {
    let data = try #require(events.compactMap { event -> Data? in
        if case let .write(data) = event { return data }
        return nil
    }.first)
    return try #require(HydraChannelProtocol.Frame.decode(data)?.frame)
}

@Test func handshakeUsesTheClientKeyAndKeepsItOutOfTheSnapshotAndLogs() async throws {
    let log = MemoryChannelLog()
    let channel = client(log: log)
    let challenge = await channel.receive(frame(.authChallengeRequest, 7, "ignored"))
    let nonceFrame = try writtenFrame(challenge)
    #expect(nonceFrame.messageType == HydraChannelProtocol.MessageType.authChallenge.rawValue)
    #expect(nonceFrame.sequence == 0)
    let nonceBytes = try #require(Data(base64Encoded: nonceFrame.payload))
    #expect(nonceBytes.count == HydraChannelProtocol.nonceByteCount)
    #expect(!challenge.contains(.close))

    let mac = ChannelAuthenticator.hmacBase64(secret: clientKey, nonce: nonceFrame.payload)
    let accepted = await channel.receive(frame(.authResponse, 1, mac))
    #expect(accepted.isEmpty)

    let request = #"{"cmd":"fullinventory","param":""}"#
    let response = await channel.receive(frame(.jsonRequest, 44, request))
    let body = try writtenFrame(response)
    #expect(body.messageType == HydraChannelProtocol.MessageType.jsonResponse.rawValue)
    #expect(body.sequence == 44)
    #expect(body.payload.contains("snapshot-marker"))
    #expect(!body.payload.contains(clientKey))

    let wire = (challenge + response).compactMap { event -> Data? in
        if case let .write(data) = event { return data }
        return nil
    }.reduce(into: Data()) { $0.append($1) }
    #expect(!String(decoding: wire, as: UTF8.self).contains(clientKey))
    #expect(!log.text.contains(clientKey))
    #expect(log.text.contains("channel authenticated"))
}

@Test func mismatchedAuthResponseClosesTheChannel() async throws {
    let log = MemoryChannelLog()
    let channel = client(log: log)
    _ = await channel.receive(frame(.authChallengeRequest, 1, ""))
    let rejected = await channel.receive(frame(.authResponse, 1, "bm90LXRoZS1tYWM="))
    #expect(rejected == [.close])
    #expect(!log.text.contains(clientKey))
    let followUp = await channel.receive(frame(.jsonRequest, 2, #"{"cmd":"ping"}"#))
    #expect(followUp.isEmpty)
}

@Test func shortAndInvalidFramesAreRejected() async {
    let log = MemoryChannelLog()
    let channel = client(log: log)
    let short = await channel.receive(Data(repeating: 0, count: 10))
    #expect(short == [.close])

    let channel2 = client(log: MemoryChannelLog())
    var bad = frame(.authChallengeRequest, 0, "")
    bad[4] = 0x00
    let magic = await channel2.receive(bad)
    #expect(magic == [.close])

    let channel3 = client(log: MemoryChannelLog())
    var length = frame(.authChallengeRequest, 0, "x")
    length[0] = 100
    length[1] = 0
    length[2] = 0
    length[3] = 0
    let unfit = await channel3.receive(length)
    #expect(unfit == [.close])
}

@Test func authenticatedCommandsUseTheRequestSequence() async throws {
    let log = MemoryChannelLog()
    let channel = client(log: log)
    let challenge = await channel.receive(frame(.authChallengeRequest, 3, ""))
    let nonce = try writtenFrame(challenge).payload
    let mac = ChannelAuthenticator.hmacBase64(secret: clientKey, nonce: nonce)
    _ = await channel.receive(frame(.authResponse, 9, mac))

    let ping = try writtenFrame(await channel.receive(frame(.jsonRequest, 8, #"{"cmd":"ping","param":""}"#)))
    #expect(ping.sequence == 8)
    #expect(ping.payload.contains(#""status":"Pong""#))
    #expect(ping.payload.contains(#""type":"response""#))
    #expect(ping.payload.contains(#""request_seq":8"#))

    let time = try writtenFrame(await channel.receive(frame(.jsonRequest, 9, #"{"cmd":"gettime"}"#)))
    #expect(time.payload.contains(#""status":"Client time is "#))

    let other = try writtenFrame(await channel.receive(frame(.jsonRequest, 10, #"{"cmd":"whatever"}"#)))
    #expect(other.payload.contains(#""status":"Client CPU Usage is 12.5 %""#))

    let network = try writtenFrame(await channel.receive(frame(
        .jsonRequest,
        11,
        #"{"cmd":"network","param":"https://example.test/bandwidth"}"#
    )))
    #expect(network.payload.contains(#""IsAvailable":false"#))
    #expect(network.payload.contains("Bandwidth was not measured."))
    #expect(!network.payload.contains("Mbps"))
    #expect(!network.payload.contains("bandwidthMeasured"))
    #expect(!network.payload.contains(clientKey))

    let location = try writtenFrame(await channel.receive(frame(.jsonRequest, 12, #"{"cmd":"location"}"#)))
    #expect(location.payload.contains(#""IsAvailable":false"#))
    #expect(!location.payload.contains(#""available":false"#))

    let inventory = try writtenFrame(await channel.receive(frame(.jsonRequest, 13, #"{"cmd":"fullinventory"}"#)))
    #expect(inventory.payload.contains(#""CollectedAtUtc":"#))
    #expect(inventory.payload.contains("snapshot-marker"))
    #expect(!inventory.payload.contains("schemaVersion"))

    let oversized = Data(repeating: 1, count: HydraChannelProtocol.maximumAcceptedBytes + 1)
    let dropped = await channel.receive(oversized)
    #expect(dropped.isEmpty)
    #expect(!log.text.contains(clientKey))
}

@Test func inventoryUsesTheWindowsPropertyNamesTheAgentDisplays() async throws {
    let channel = HydraChannelClient(
        clientKey: clientKey,
        inventory: RichInventory(),
        log: MemoryChannelLog(),
        trace: { _, _ in nil }
    )
    let challenge = await channel.receive(frame(.authChallengeRequest, 1, ""))
    let nonce = try writtenFrame(challenge).payload
    let mac = ChannelAuthenticator.hmacBase64(secret: clientKey, nonce: nonce)
    _ = await channel.receive(frame(.authResponse, 1, mac))

    let inventory = try writtenFrame(await channel.receive(frame(.jsonRequest, 4, #"{"cmd":"fullinventory"}"#)))
    let object = try jsonObject(inventory.payload)
    let operatingSystem = try section(object, "OperatingSystem")
    #expect(operatingSystem["ProductName"] as? String == "macOS")
    #expect(operatingSystem["MachineName"] as? String == "ada-mac")
    #expect(operatingSystem["PrimaryIPv4Address"] as? String == "10.1.2.3")
    #expect(operatingSystem["UserName"] as? String == "ada")

    let bios = try section(object, "Bios")
    #expect(bios["SystemModel"] as? String == "Mac14,1")

    let cpus = try #require(object["Cpus"] as? [[String: Any]])
    #expect(cpus.first?["Name"] as? String == "Apple M2")
    #expect(cpus.first?["LogicalProcessors"] as? Int == 8)
    #expect(cpus.first?["UtilizationPercentage"] as? Double == 12.5)

    let drives = try #require(object["Drives"] as? [[String: Any]])
    #expect(drives.first?["Name"] as? String == "/")
    #expect(drives.first?["TotalSizeBytes"] as? Int == 1000)
    #expect(drives.first?["FreeSpaceBytes"] as? Int == 400)

    let apps = try #require(object["InstalledApplications"] as? [[String: Any]])
    #expect(apps.first?["DisplayName"] as? String == "Safari")
    #expect(apps.first?["DisplayVersion"] as? String == "17.0")

    let adapters = try #require(object["NetworkAdapters"] as? [[String: Any]])
    let en0 = try #require(adapters.first { $0["Name"] as? String == "en0" })
    #expect(en0["Ssid"] as? String == "Office")
    #expect(en0["IPv4Addresses"] as? [String] == ["10.1.2.3"])
    #expect(en0["DefaultGateway"] as? String == "10.1.2.1")

    let battery = try section(object, "Battery")
    #expect(battery["ChargePercentage"] as? Int == 80)
    #expect(battery["IsCharging"] as? Bool == true)

    let monitors = try #require(object["Monitors"] as? [[String: Any]])
    #expect(monitors.first?["WidthPixels"] as? Int == 1512)
    #expect(monitors.first?["IsPrimary"] as? Bool == true)

    let identity = try section(object, "UserIdentity")
    #expect(identity["UserName"] as? String == "ada")

    let firewall = try section(object, "Firewall")
    #expect(firewall["PublicProfileEnabled"] as? Bool == true)

    let place = try section(object, "Location")
    #expect(place["Latitude"] as? Double == 52.5)

    let disks = try #require(object["PhysicalDisks"] as? [[String: Any]])
    #expect(disks.first?["SerialNumber"] as? String == "C02")

    let errors = try #require(object["AllErrors"] as? [[String: Any]])
    #expect(errors.contains { $0["Message"] as? String == "disk-smart" })
    #expect(!inventory.payload.contains(clientKey))
    #expect(!inventory.payload.contains("schemaVersion"))

    let located = try writtenFrame(await channel.receive(frame(.jsonRequest, 5, #"{"cmd":"location"}"#)))
    let locationObject = try jsonObject(located.payload)
    let location = try #require(locationObject["Value"] as? [String: Any])
    #expect(location["Latitude"] as? Double == 52.5)
    #expect(locationObject["IsAvailable"] as? Bool == true)

    let networkFrame = try writtenFrame(await channel.receive(frame(.jsonRequest, 6, #"{"cmd":"network"}"#)))
    let network = try jsonObject(networkFrame.payload)
    let provider = try section(network, "Provider")
    #expect(provider["PublicIp"] as? String == "203.0.113.5")
    let internet = try section(network, "InternetLatency")
    #expect(internet["AvgMs"] as? Double == 18)
    let bandwidth = try #require(network["Bandwidth"] as? [String: Any])
    #expect(bandwidth["IsAvailable"] as? Bool == false)

    let performance = try writtenFrame(await channel.receive(frame(.jsonRequest, 7, #"{"cmd":"performance"}"#)))
    let rows = try #require(JSONSerialization.jsonObject(with: Data(performance.payload.utf8)) as? [[String: Any]])
    let cpu = try #require(rows.first?["Cpu"] as? [String: Any])
    #expect(cpu["UtilizationPercentage"] as? Double == 12.5)
    let latency = try #require(rows.first?["Latency"] as? [String: Any])
    #expect(latency["InternetReachable"] as? Bool == true)
    #expect(latency["InternetLatencyMs"] as? Double == 18)
}

@Test func memoryUsedCountsActiveAnonymousWiredAndCompressedPages() {
    let page: Int64 = 16_384
    let used = EndpointInventory.activeUsedMemoryBytes(
        internalPages: 744_997,
        purgeablePages: 33_372,
        wiredPages: 203_474,
        compressedPages: 615_509,
        pageSize: page
    )
    let app = 744_997 - 33_372
    #expect(used == Int64(app + 203_474 + 615_509) * page)

    let withoutFileCache = EndpointInventory.activeUsedMemoryBytes(
        internalPages: 100,
        purgeablePages: 40,
        wiredPages: 10,
        compressedPages: 5,
        pageSize: page
    )
    #expect(withoutFileCache == Int64(60 + 10 + 5) * page)
    #expect(EndpointInventory.activeUsedMemoryBytes(
        internalPages: 10,
        purgeablePages: 40,
        wiredPages: 0,
        compressedPages: 0,
        pageSize: page
    ) == 0)
}

private final class RichInventory: InventoryProviding {
    func loadSnapshot() async -> ClientSnapshot {
        ClientSnapshot(
            collectedAtUtc: Date(timeIntervalSince1970: 1_700_000_000),
            device: DeviceSection(
                productName: "macOS",
                productVersion: "15.1",
                buildVersion: "24B83",
                hardwareModel: "Mac14,1",
                cpuBrand: "Apple M2",
                cpuCount: 8,
                memoryBytes: 16_000_000_000,
                disks: [DiskInfo(mountPoint: "/", totalBytes: 1000, availableBytes: 400, fileSystem: "apfs")],
                gpus: ["Apple M2"],
                displays: [DisplayInfo(width: 1512, height: 982, scaleFactor: 2)],
                battery: BatteryInfo(present: true, chargePercentage: 80, isCharging: true)
            ),
            software: SoftwareSection(applications: [ApplicationInfo(name: "Safari", version: "17.0")]),
            network: NetworkSection(
                interfaces: [
                    InterfaceInfo(name: "en0", address: "10.1.2.3", family: "ipv4"),
                    InterfaceInfo(name: "lo0", address: "127.0.0.1", family: "ipv4")
                ],
                gateway: GatewayInfo(address: "10.1.2.1", interfaceName: "en0"),
                internetPing: PingSample(target: "1.1.1.1", reachable: true, latencyMs: 18, skipped: false),
                gatewayPing: PingSample(target: "10.1.2.1", reachable: true, latencyMs: 2, skipped: false),
                publicIp: "203.0.113.5"
            ),
            security: SecuritySection(fileVaultEnabled: true, firewallEnabled: true),
            sensitive: SensitiveSection(
                userName: "ada",
                computerName: "ada-mac",
                serialNumber: "C02",
                wifiSsid: "Office",
                location: LocationFix(latitude: 52.5, longitude: 13.4)
            ),
            errors: ["disk-smart"]
        )
    }

    func cpuPercent() -> Double { 12.5 }
}

private func jsonObject(_ payload: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
}

private func section(_ object: [String: Any], _ name: String) throws -> [String: Any] {
    let wrapped = try #require(object[name] as? [String: Any])
    #expect(wrapped["IsAvailable"] as? Bool == true)
    return try #require(wrapped["Value"] as? [String: Any])
}

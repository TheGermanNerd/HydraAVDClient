import Foundation
import HydraAgentCore
import Testing
@testable import HydraRdpCore

@Test func performanceHistoryFeedsTheEndpointGraphs() throws {
    let monitor = PerformanceMonitor()
    var time = Date(timeIntervalSince1970: 1_700_000_000)
    monitor.now = { time }
    monitor.setNetworkInterface("en0")
    var phase = 0
    monitor.counters = {
        phase += 1
        if phase == 1 {
            return (
                disks: [DiskCounter(name: "disk0", readBytes: 1_000, writeBytes: 0, readOperations: 10, writeOperations: 0, busyNanoseconds: 0)],
                networks: [
                    NetworkCounter(name: "en0", ipv4: "10.1.2.3", receiveBytes: 0, transmitBytes: 0, receivePackets: 0, transmitPackets: 0, linkSpeedBps: 1_000_000),
                    NetworkCounter(name: "en1", ipv4: "192.168.1.9", receiveBytes: 0, transmitBytes: 0, receivePackets: 0, transmitPackets: 0, linkSpeedBps: 0)
                ]
            )
        }
        return (
            disks: [DiskCounter(name: "disk0", readBytes: 6_000, writeBytes: 500, readOperations: 20, writeOperations: 5, busyNanoseconds: 2_500_000_000)],
            networks: [
                NetworkCounter(name: "en0", ipv4: "10.1.2.3", receiveBytes: 5_000, transmitBytes: 2_500, receivePackets: 10, transmitPackets: 5, linkSpeedBps: 1_000_000),
                NetworkCounter(name: "en1", ipv4: "192.168.1.9", receiveBytes: 9_000, transmitBytes: 0, receivePackets: 0, transmitPackets: 0, linkSpeedBps: 0)
            ]
        )
    }

    let snapshot = ClientSnapshot(
        collectedAtUtc: time,
        network: NetworkSection(
            interfaces: [],
            gateway: nil,
            internetPing: PingSample(target: "8.8.8.8", reachable: true, latencyMs: 12, skipped: false),
            gatewayPing: nil,
            publicIp: nil
        )
    )
    _ = monitor.record(snapshot: snapshot)
    time = time.addingTimeInterval(5)
    let payload = monitor.record(snapshot: snapshot)
    let rows = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
    #expect(rows.count == 2)

    let disks = try #require(rows[1]["Disks"] as? [[String: Any]])
    #expect(disks.count == 1)
    #expect(disks[0]["DiskName"] as? String == "disk0")
    #expect(number(disks[0]["ReadBytesPerSecond"]) == 1_000)
    #expect(number(disks[0]["ReadIops"]) == 2)
    #expect(number(disks[0]["WriteBytesPerSecond"]) == 100)
    #expect(number(disks[0]["UtilizationPercentage"]) == 50)

    let networks = try #require(rows[1]["Networks"] as? [[String: Any]])
    #expect(networks.count == 1)
    #expect(networks[0]["InterfaceName"] as? String == "en0")
    #expect(networks[0]["IPv4Address"] as? String == "10.1.2.3")
    #expect(number(networks[0]["ReceiveBytesPerSecond"]) == 1_000)
    #expect(number(networks[0]["ReceiveUtilizationPercentage"]) == 0.8)
    #expect(networks[0]["WifiLinkSpeedBps"] as? Int == 1_000_000)

    let latency = try #require(rows[1]["Latency"] as? [String: Any])
    #expect(latency["InternetLatencyMs"] as? Double == 12)
    #expect(latency["InternetReachable"] as? Bool == true)

    let memory = try #require(rows[1]["Memory"] as? [String: Any])
    #expect(memory["TotalBytes"] != nil)
    #expect(memory["UsedPercentage"] != nil)
}

@Test func performanceHistoryDropsSamplesOutsideTheHour() throws {
    var series = PerformanceSeries()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let sample = EndpointInventory.performanceSample(
        at: start,
        cpuPercent: 1,
        totalMemoryBytes: 100,
        usedMemoryBytes: 40,
        disks: [],
        networks: [],
        latency: EndpointInventory.emptyLatency()
    )
    series.append(sample, at: start)
    series.append(sample, at: start.addingTimeInterval(5))
    let later = start.addingTimeInterval(60 * 60 + 6)
    series.append(sample, at: later)
    #expect(series.count == 1)

    for index in 0..<PerformanceSeries.maximumCount {
        series.append(sample, at: later.addingTimeInterval(TimeInterval(index + 1)))
    }
    #expect(series.count == PerformanceSeries.maximumCount)
}

private func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

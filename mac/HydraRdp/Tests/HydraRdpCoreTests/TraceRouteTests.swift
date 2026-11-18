import Foundation
import HydraAgentCore
import Testing
@testable import HydraRdpCore

private let reachedTrace = """
traceroute to 8.8.8.8 (8.8.8.8), 30 hops max, 52 byte packets
 1  router.home (192.168.1.1)  1.234 ms  1.102 ms *
 2  * * *
 3  dns.google (8.8.8.8)  12.5 ms  11.8 ms  12.1 ms
"""

private let silentCutoff = """
traceroute to 8.8.8.8 (8.8.8.8), 30 hops max, 52 byte packets
 1  router.home (192.168.1.1)  1.2 ms  1.1 ms  1.0 ms
 2  * * *
 3  * * *
 4  * * *
 5  8.8.8.8 (8.8.8.8)  12.5 ms  11.8 ms  12.1 ms
"""

@Test func traceRouteListsEachHopLatencyAndMarksTheTarget() {
    let result = TraceRouteParser.parse(reachedTrace, target: "8.8.8.8")
    #expect(result.reachedTarget)
    #expect(result.hops.count == 3)

    let first = result.hops[0]
    #expect(first.hopNumber == 1)
    #expect(first.address == "192.168.1.1")
    #expect(first.hostName == "router.home")
    #expect(first.latenciesMs == [1.234, 1.102, 0])
    #expect(!first.timedOut)
    #expect(!first.reachedTarget)

    let silent = result.hops[1]
    #expect(silent.hopNumber == 2)
    #expect(silent.address == nil)
    #expect(silent.hostName == nil)
    #expect(silent.latenciesMs == [0, 0, 0])
    #expect(silent.timedOut)
    #expect(!silent.reachedTarget)

    let last = result.hops[2]
    #expect(last.address == "8.8.8.8")
    #expect(last.hostName == "dns.google")
    #expect(last.latenciesMs == [12.5, 11.8, 12.1])
    #expect(last.reachedTarget)
}

@Test func traceRouteDropsHopsAfterThreeSilentHops() {
    let result = TraceRouteParser.parse(silentCutoff, target: "8.8.8.8")
    #expect(result.hops.map(\.hopNumber) == [1, 2, 3, 4])
    #expect(!result.reachedTarget)
    #expect(result.hops[1].timedOut)
    #expect(result.hops[2].timedOut)
    #expect(result.hops[3].timedOut)
}

@Test func traceRouteCommandMatchesTheMsiProbe() {
    let icmp = TraceRouteRunner.arguments(target: "8.8.8.8", interfaceName: "en0", icmp: true)
    #expect(icmp == ["-q", "3", "-m", "30", "-w", "1", "-i", "en0", "-I", "8.8.8.8"])

    let udp = TraceRouteRunner.arguments(target: "8.8.8.8", interfaceName: nil, icmp: false)
    #expect(udp == ["-q", "3", "-m", "30", "-w", "1", "8.8.8.8"])
    #expect(TraceRouteRunner.arguments(target: "8.8.8.8", interfaceName: "en0; rm", icmp: true)?
        .contains("-i") == false)
    #expect(TraceRouteRunner.arguments(target: "-n", interfaceName: nil, icmp: true) == nil)
    #expect(TraceRouteRunner.shouldRetryWithoutIcmp(
        output: "traceroute: icmp socket: Operation not permitted",
        hopCount: 0
    ))
    #expect(!TraceRouteRunner.shouldRetryWithoutIcmp(output: "not permitted", hopCount: 2))
}

@Test func networkTraceRouteUsesTheWindowsHopShape() throws {
    let trace = TraceRouteParser.parse(reachedTrace, target: "8.8.8.8")
    let body = makeSnapshot(ping: PingSample(target: "8.8.8.8", reachable: true, latencyMs: 12, skipped: false))
    let network = try jsonObject(EndpointInventory.network(body, parameter: "", trace: trace))

    let internet = try section(network, "InternetLatency")
    #expect(internet["AvgMs"] as? Double == 12)

    let route = try section(network, "TraceRoute")
    #expect(route["Target"] as? String == "8.8.8.8")
    #expect(route["ReachedTarget"] as? Bool == true)
    let hops = try #require(route["Hops"] as? [[String: Any]])
    #expect(hops.count == 3)
    #expect(hops[0]["HopNumber"] as? Int == 1)
    #expect(hops[0]["Address"] as? String == "192.168.1.1")
    #expect(hops[0]["HostName"] as? String == "router.home")
    #expect(numbers(hops[0]["LatenciesMs"]) == [1.234, 1.102, 0])
    #expect(hops[1]["TimedOut"] as? Bool == true)
    #expect(hops[1]["HostName"] is NSNull)
    #expect(hops[1]["Address"] is NSNull)
    #expect(hops[2]["ReachedTarget"] as? Bool == true)
    #expect(numbers(hops[2]["LatenciesMs"]) == [12.5, 11.8, 12.1])
}

@Test func skippedPingLeavesTraceRouteUnavailable() throws {
    let skipped = makeSnapshot(ping: PingSample(target: "8.8.8.8", reachable: false, latencyMs: nil, skipped: true))
    let network = try jsonObject(EndpointInventory.network(skipped, parameter: ""))
    let route = try #require(network["TraceRoute"] as? [String: Any])
    #expect(route["IsAvailable"] as? Bool == false)
    #expect(route["Value"] is NSNull)
    let errors = try #require(route["Errors"] as? [[String: Any]])
    #expect(errors.first?["Collector"] as? String == "TraceRoute")
    #expect(errors.first?["Message"] as? String == "Ping was skipped.")

    let missing = try jsonObject(EndpointInventory.network(makeSnapshot(ping: nil), parameter: ""))
    let missingRoute = try #require(missing["TraceRoute"] as? [String: Any])
    let missingErrors = try #require(missingRoute["Errors"] as? [[String: Any]])
    #expect(missingErrors.first?["Message"] as? String == "No ping sample was collected.")
}

private func makeSnapshot(ping: PingSample?) -> ClientSnapshot {
    ClientSnapshot(
        collectedAtUtc: Date(timeIntervalSince1970: 1_700_000_000),
        network: NetworkSection(
            interfaces: [InterfaceInfo(name: "en0", address: "10.0.0.8", family: "ipv4")],
            gateway: GatewayInfo(address: "10.0.0.1", interfaceName: "en0"),
            internetPing: ping,
            gatewayPing: nil,
            publicIp: nil
        )
    )
}

private func jsonObject(_ payload: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
}

private func section(_ object: [String: Any], _ name: String) throws -> [String: Any] {
    let wrapped = try #require(object[name] as? [String: Any])
    #expect(wrapped["IsAvailable"] as? Bool == true)
    return try #require(wrapped["Value"] as? [String: Any])
}

private func numbers(_ value: Any?) -> [Double] {
    let items = value as? [Any] ?? []
    return items.compactMap { item in
        (item as? NSNumber)?.doubleValue
    }
}

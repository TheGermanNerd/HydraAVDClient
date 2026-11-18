import Testing
@testable import HydraAgentCore

@Test func successfulPing() {
    let output = """
    PING 8.8.8.8 (8.8.8.8): 56 data bytes
    64 bytes from 8.8.8.8: icmp_seq=0 ttl=117 time=12.345 ms

    --- 8.8.8.8 ping statistics ---
    1 packets transmitted, 1 packets received, 0.0% packet loss
    round-trip min/avg/max/stddev = 12.345/12.345/12.345/0.000 ms
    """
    let parsed = PingParser.parse(output)
    #expect(parsed.reachable)
    #expect(abs((parsed.latencyMs ?? -1) - 12.345) < 0.001)
}

@Test func subMillisecondPing() {
    let output = """
    64 bytes from 10.0.0.1: icmp_seq=0 ttl=64 time<1 ms
    1 packets transmitted, 1 packets received, 0.0% packet loss
    """
    let parsed = PingParser.parse(output)
    #expect(parsed.reachable)
    #expect(abs((parsed.latencyMs ?? -1) - 1) < 0.001)
}

@Test func totalPacketLoss() {
    let output = """
    PING 8.8.8.8 (8.8.8.8): 56 data bytes
    Request timeout for icmp_seq 0

    --- 8.8.8.8 ping statistics ---
    1 packets transmitted, 0 packets received, 100.0% packet loss
    """
    let parsed = PingParser.parse(output)
    #expect(!parsed.reachable)
    #expect(parsed.latencyMs == nil)
}

@Test func unknownHost() {
    let parsed = PingParser.parse("ping: cannot resolve bad..host: Unknown host\n")
    #expect(!parsed.reachable)
    #expect(parsed.latencyMs == nil)
}

@Test func emptyOutput() {
    let parsed = PingParser.parse("")
    #expect(!parsed.reachable)
    #expect(parsed.latencyMs == nil)
}

@Test func validTargets() {
    #expect(PingParser.isValidTarget("8.8.8.8"))
    #expect(PingParser.isValidTarget("dns.google"))
    #expect(PingParser.isValidTarget(" 1.1.1.1 "))
    #expect(!PingParser.isValidTarget(""))
    #expect(!PingParser.isValidTarget("8.8.8.8; rm -rf"))
    #expect(!PingParser.isValidTarget("foo bar"))
    #expect(!PingParser.isValidTarget("-n"))
    #expect(!PingParser.isValidTarget("bad..host"))
}

@Test func firewallDisabledDoesNotCountAsEnabled() {
    #expect(SecurityStatusParser.firewallEnabled(from: "Firewall is disabled. (State = 0)") == false)
    #expect(SecurityStatusParser.firewallEnabled(from: "Firewall is enabled. (State = 1)") == true)
}

@Test func fileVaultStatus() {
    #expect(SecurityStatusParser.fileVaultEnabled(from: "FileVault is On.") == true)
    #expect(SecurityStatusParser.fileVaultEnabled(from: "FileVault is Off.") == false)
    #expect(SecurityStatusParser.fileVaultEnabled(from: "Error: something failed") == nil)
}

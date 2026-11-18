import Foundation
import Testing
@testable import HydraRdpCore

@Test func tlsOnlyRefusalMeansNetworkLevelAuthentication() {
    let refused = Data([
        0x03, 0x00, 0x00, 0x13, 0x0e, 0xd0, 0x00, 0x00, 0x12, 0x34, 0x00,
        0x03, 0x00, 0x08, 0x00, 0x05, 0x00, 0x00, 0x00
    ])
    #expect(RdpSecurityProbe.parse(refused) == .failure(5))
    #expect(RdpSecurityProbe.requiresNetworkLevelAuthentication(responseToTlsOnly: refused))
}

@Test func selectedTlsDoesNotRequireCredentialsFirst() {
    let accepted = Data([
        0x03, 0x00, 0x00, 0x13, 0x0e, 0xd0, 0x00, 0x00, 0x12, 0x34, 0x00,
        0x02, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00
    ])
    #expect(RdpSecurityProbe.parse(accepted) == .selected(1))
    #expect(!RdpSecurityProbe.requiresNetworkLevelAuthentication(responseToTlsOnly: accepted))
}

@Test func hostAndPortSplit() {
    #expect(RdpSecurityProbe.endpoint(from: "10.103.1.137")?.name == "10.103.1.137")
    #expect(RdpSecurityProbe.endpoint(from: "10.103.1.137")?.port == 3389)
    #expect(RdpSecurityProbe.endpoint(from: "pc.contoso.local:3390")?.port == 3390)
    #expect(RdpSecurityProbe.endpoint(from: "[2001:db8::1]:3389")?.name == "2001:db8::1")
    #expect(RdpSecurityProbe.endpoint(from: "  pc.contoso.local  ")?.name == "pc.contoso.local")
    #expect(RdpSecurityProbe.endpoint(from: "   ") == nil)
}

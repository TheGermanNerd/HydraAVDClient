import Foundation
import Testing
@testable import HydraRdpCore

private let avdFile = """
full address:s:rdgateway.wvd.microsoft.com
username:s:user@contoso.com
gatewayhostname:s:rdbroker.wvd.microsoft.com
loadbalanceinfo:s:tsv://MS Terminal Services Plugin.1.Finance
enablerdsaadauth:i:1
resourceprovider:s:arm
gatewayaccesstoken:s:secret-token-value
password:s:secret-password-value
remoteapplicationmode:i:1
remoteapplicationprogram:s:||Excel
remoteapplicationname:s:Excel
aadtenantid:s:tenant-guid
desktopwidth:i:1600
desktopheight:i:900
"""

@Test func avdFileMapsOntoFreeRDP() {
    let parsed = RdpFileParser.parse(avdFile)
    #expect(parsed.usesArmGateway)
    #expect(parsed.usesEntraAuth)
    #expect(parsed.fullAddress == "rdgateway.wvd.microsoft.com")
    #expect(parsed.gatewayHostname == "rdbroker.wvd.microsoft.com")
    #expect(parsed.loadBalanceInfo == "tsv://MS Terminal Services Plugin.1.Finance")
    #expect(parsed.remoteApplicationProgram == "||Excel")
    #expect(parsed.remoteApplicationMode)

    let launch = FreeRdpLaunchBuilder.workspace(
        file: parsed,
        rdpText: avdFile,
        accessToken: "fresh-entra-token",
        width: 1280,
        height: 720
    )
    let joined = launch.arguments.joined(separator: "\n")
    #expect(launch.armGateway)
    #expect(launch.entraAuth)
    #expect(launch.remoteApp)
    #expect(joined.contains("/gateway:type:arm,g:rdbroker.wvd.microsoft.com"))
    #expect(joined.contains("/sec:aad"))
    #expect(joined.contains("/load-balance-info:tsv://MS Terminal Services Plugin.1.Finance"))
    #expect(joined.contains("/app:program:||Excel,name:Excel"))
    #expect(joined.contains("/dvc:HYDAGX01"))
    #expect(joined.contains("/dynamic-resolution"))
    #expect(joined.contains("+clipboard"))
    #expect(launch.accessToken == "fresh-entra-token")
    #expect(!joined.contains("secret-token-value"))
    #expect(!joined.contains("secret-password-value"))
    #expect(!joined.contains("fresh-entra-token"))
    #expect(launch.width == 1600)
    #expect(launch.height == 900)
}

@Test func zeroDesktopSizeUsesTheClientSize() {
    let text = """
    full address:s:rdgateway.wvd.microsoft.com
    desktopwidth:i:0
    desktopheight:i:0
    """
    let launch = FreeRdpLaunchBuilder.workspace(
        file: RdpFileParser.parse(text),
        rdpText: text,
        accessToken: nil,
        width: 3024,
        height: 1738
    )
    #expect(launch.width == 3024)
    #expect(launch.height == 1738)
    #expect(launch.arguments.contains("/w:3024"))
    #expect(launch.arguments.contains("/h:1738"))
}

@Test func directDesktopOmitsThePassword() {
    let launch = FreeRdpLaunchBuilder.direct(
        host: "pc.contoso.local",
        user: "CONTOSO\\ada",
        password: "desktop-secret",
        gatewayHost: "gw.contoso.local",
        gatewayUser: "CONTOSO\\ada",
        gatewayPassword: "gateway-secret",
        width: 1280,
        height: 720
    )
    let joined = launch.arguments.joined(separator: "\n")
    #expect(joined.contains("/v:pc.contoso.local"))
    #expect(joined.contains("/d:CONTOSO"))
    #expect(joined.contains("/u:ada"))
    #expect(joined.contains("/gateway:g:gw.contoso.local,type:auto"))
    #expect(joined.contains("/gu:CONTOSO\\ada"))
    #expect(!launch.armGateway)
    #expect(!launch.entraAuth)
    #expect(!launch.remoteApp)
    #expect(launch.password == "desktop-secret")
    #expect(launch.gatewayPassword == "gateway-secret")
    #expect(!joined.contains("desktop-secret"))
    #expect(!joined.contains("gateway-secret"))
    #expect(joined.contains("/multitransport:udp"))
    #expect(joined.contains("/proxy:ignore"))
}

@Test func connectionSwitchesChangeTheLaunch() {
    let directOff = FreeRdpLaunchBuilder.direct(
        host: "pc.contoso.local",
        user: "ada",
        password: nil,
        gatewayHost: nil,
        gatewayUser: nil,
        gatewayPassword: nil,
        width: 1280,
        height: 720,
        connection: SessionConnection(useUDP: false, proxyArgument: "http://proxy.contoso.com:8080")
    )
    let directJoined = directOff.arguments.joined(separator: "\n")
    #expect(directJoined.contains("/multitransport:tcp-only"))
    #expect(directJoined.contains("/proxy:http://proxy.contoso.com:8080"))
    #expect(!directJoined.contains("/multitransport:udp"))

    let text = "full address:s:rdgateway.wvd.microsoft.com\n"
    let workspaceOn = FreeRdpLaunchBuilder.workspace(
        file: RdpFileParser.parse(text),
        rdpText: text,
        accessToken: nil,
        width: 1280,
        height: 720,
        connection: SessionConnection(useUDP: true, proxyArgument: GatewayProxy.ignore)
    )
    let workspaceJoined = workspaceOn.arguments.joined(separator: "\n")
    #expect(workspaceJoined.contains("/multitransport:udp"))
    #expect(workspaceJoined.contains("/proxy:ignore"))
    #expect(!workspaceJoined.contains("/multitransport:tcp-only"))
}

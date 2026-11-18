import CFNetwork
import Foundation
import Testing
@testable import HydraRdpCore

@Test func disabledProxyIgnoresAnHTTPProxy() {
    let argument = GatewayProxy.argument(enabled: false, proxies: [httpProxy(host: "proxy.contoso.com", port: 8080)])
    #expect(argument == GatewayProxy.ignore)
}

@Test func httpAndHTTPSProxiesBecomeAFreeRDPURI() {
    #expect(GatewayProxy.argument(enabled: true, proxies: [httpProxy(host: "proxy.contoso.com", port: 8080)]) == "http://proxy.contoso.com:8080")
    let https = httpProxy(host: "secure.contoso.com", port: 8443, type: kCFProxyTypeHTTPS as String)
    #expect(GatewayProxy.argument(enabled: true, proxies: [https]) == "http://secure.contoso.com:8443")
}

@Test func missingProxyOrABypassIsIgnored() {
    #expect(GatewayProxy.argument(enabled: true, proxies: []) == GatewayProxy.ignore)
    let bypass: [String: Any] = [kCFProxyTypeKey as String: kCFProxyTypeNone as String]
    #expect(GatewayProxy.argument(enabled: true, proxies: [bypass]) == GatewayProxy.ignore)
    let socks: [String: Any] = [
        kCFProxyTypeKey as String: kCFProxyTypeSOCKS as String,
        kCFProxyHostNameKey as String: "socks.contoso.com",
        kCFProxyPortNumberKey as String: 1080
    ]
    #expect(GatewayProxy.argument(enabled: true, proxies: [socks]) == GatewayProxy.ignore)
}

@Test func proxyLoginIsIncludedWhenBothPartsAreSafe() {
    var proxy = httpProxy(host: "proxy.contoso.com", port: 8080)
    proxy[kCFProxyUsernameKey as String] = "ada"
    proxy[kCFProxyPasswordKey as String] = "s3cret"
    #expect(GatewayProxy.argument(enabled: true, proxies: [proxy]) == "http://ada:s3cret@proxy.contoso.com:8080")
}

@Test func aLoginThatWouldBreakTheFreeRDPSplitIsLeftOff() {
    var proxy = httpProxy(host: "proxy.contoso.com", port: 8080)
    proxy[kCFProxyUsernameKey as String] = "ada"
    proxy[kCFProxyPasswordKey as String] = "se@cret"
    #expect(GatewayProxy.argument(enabled: true, proxies: [proxy]) == "http://proxy.contoso.com:8080")
}

private func httpProxy(host: String, port: Int, type: String = kCFProxyTypeHTTP as String) -> [String: Any] {
    [
        kCFProxyTypeKey as String: type,
        kCFProxyHostNameKey as String: host,
        kCFProxyPortNumberKey as String: port
    ]
}

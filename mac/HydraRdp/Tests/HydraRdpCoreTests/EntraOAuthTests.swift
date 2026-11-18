import Foundation
import Testing
@testable import HydraRdpCore

@Test func signInUsesTheBuiltInRemoteDesktopClient() throws {
    let authorization = try EntraOAuth.start()
    let items = URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    #expect(authorization.clientID == "a85cf173-4192-42f8-81fa-777a763e6e2c")
    #expect(authorization.tenant == "common")
    #expect(authorization.redirectURI == "ms-appx-web://Microsoft.AAD.BrokerPlugin/a85cf173-4192-42f8-81fa-777a763e6e2c")
    #expect(authorization.url.host == "login.microsoftonline.com")
    #expect(authorization.url.path == "/common/oauth2/v2.0/authorize")
    #expect(value("client_id") == EntraOAuth.clientID)
    #expect(value("redirect_uri") == EntraOAuth.redirectURI)
    #expect(value("scope")?.contains("https://www.wvd.microsoft.com/.default") == true)
    #expect(value("response_type") == "code")
    #expect(value("code_challenge") == nil)
    #expect(WorkspaceFeed.discoveryURL.absoluteString == "https://rdweb.wvd.microsoft.com/api/arm/feeddiscovery")
}

@Test func accountProfileReadsTheEntraTokenClaims() {
    let payload = #"{"name":"Ada Lovelace","preferred_username":"ada@contoso.com"}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let profile = EntraIdentity.profile(accessToken: "e30.\(encoded).sig")
    #expect(profile?.name == "Ada Lovelace")
    #expect(profile?.username == "ada@contoso.com")
    #expect(EntraIdentity.profile(accessToken: "not-a-token") == nil)
}

@Test func savedDesktopWithoutFavoriteStillLoads() throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"ALMERE-0","host":"almere","user":"Administrator","gatewayHost":"","gatewayUser":"","displayMode":"windowed"}"#
    let desktop = try JSONDecoder().decode(SavedDesktop.self, from: Data(json.utf8))
    #expect(desktop.isFavorite == false)
    #expect(desktop.listTitle == "ALMERE-0")
    #expect(desktop.user == "Administrator")
    let again = try JSONDecoder().decode(SavedDesktop.self, from: JSONEncoder().encode(desktop))
    #expect(again == desktop)
}

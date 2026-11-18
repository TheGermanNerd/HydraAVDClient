import Foundation
import Testing
@testable import HydraRdpCore

private let discovery = """
{
  "value": [
    {
      "TenantId": "tenant-1",
      "FriendlyName": "Contoso",
      "WorkspaceId": "ws-1",
      "FeedUrl": "https://rdweb.wvd.microsoft.com/api/arm/feed/ws-1"
    }
  ]
}
""".data(using: .utf8)!

private let resources = """
{
  "RemoteDesktop": [
    {
      "Id": "desk-1",
      "Name": "Finance Desktop",
      "Type": "Desktop",
      "RdpFileUrl": "https://rdweb.wvd.microsoft.com/api/arm/feed/desk-1/rdp"
    }
  ],
  "CloudPC": [
    {
      "Id": "cpc-1",
      "Name": "Kyle Cloud PC",
      "Type": "CloudPC",
      "RdpFileContents": "full address:s:cloud.example\\n"
    }
  ],
  "RemoteApp": [
    {
      "Id": "app-1",
      "Name": "Excel",
      "Type": "RemoteApp",
      "RdpFileUrl": "https://example.test/excel.rdp"
    }
  ]
}
""".data(using: .utf8)!

@Test func feedDiscoveryReadsTheWorkspaceURL() throws {
    let feeds = try WorkspaceFeed.parseDiscovery(discovery)
    #expect(feeds.count == 1)
    #expect(feeds[0].id == "ws-1")
    #expect(feeds[0].name == "Contoso")
    #expect(feeds[0].feedURL.absoluteString == "https://rdweb.wvd.microsoft.com/api/arm/feed/ws-1")
}

@Test func feedResourcesSeparateDesktopsCloudPCsAndApps() throws {
    let items = try WorkspaceFeed.parseResources(resources)
    #expect(items.count == 3)
    let desktop = try #require(items.first { $0.id == "desk-1" })
    #expect(desktop.kind == .desktop)
    #expect(desktop.rdpFileURL?.absoluteString == "https://rdweb.wvd.microsoft.com/api/arm/feed/desk-1/rdp")
    let cloud = try #require(items.first { $0.id == "cpc-1" })
    #expect(cloud.kind == .cloudPC)
    #expect(cloud.rdpContents?.contains("full address:s:") == true)
    let app = try #require(items.first { $0.id == "app-1" })
    #expect(app.kind == .remoteApp)
    #expect(app.name == "Excel")
}

private let workspaceXML = """
<?xml version="1.0" encoding="utf-8"?>
<ResourceCollection PubDate="2024-01-01T00:00:00Z" SchemaVersion="2.1" xmlns="http://schemas.microsoft.com/ts/2007/05/tswf">
  <Publisher LastUpdated="2024-01-01T00:00:00Z" Name="Contoso" ID="tenant-1" Description="" SupportsReconnect="true">
    <Resources>
      <Resource ID="desk-1" Alias="desk-1" Title="Finance Desktop" Type="Desktop">
        <ResourceFile FileExtension=".rdp" URL="https://rdweb.wvd.microsoft.com/api/arm/feed/desk-1/rdp"/>
      </Resource>
      <Resource ID="cpc-1" Alias="cpc-1" Title="Kyle Cloud PC" Type="CloudPC">
        <ResourceFile FileExtension=".rdp" URL="/api/arm/feed/cpc-1/rdp"/>
      </Resource>
      <Resource ID="app-1" Alias="app-1" Title="Excel" Type="RemoteApp">
        <ResourceFile FileExtension=".rdp" URL="https://example.test/excel.rdp"/>
      </Resource>
    </Resources>
  </Publisher>
</ResourceCollection>
""".data(using: .utf8)!

private let atomDiscovery = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Contoso</title>
  <entry>
    <title>Contoso workspace</title>
    <link rel="alternate" href="https://rdweb.wvd.microsoft.com/api/arm/feed/ws-1"/>
  </entry>
</feed>
""".data(using: .utf8)!

@Test func feedXMLListsDesktopsCloudPCsAndApps() throws {
    let base = URL(string: "https://rdweb.wvd.microsoft.com")!
    let items = try WorkspaceFeed.parseResources(workspaceXML, baseURL: base)
    #expect(items.count == 3)
    let desktop = try #require(items.first { $0.id == "desk-1" })
    #expect(desktop.kind == .desktop)
    #expect(desktop.rdpFileURL?.absoluteString == "https://rdweb.wvd.microsoft.com/api/arm/feed/desk-1/rdp")
    let cloud = try #require(items.first { $0.id == "cpc-1" })
    #expect(cloud.kind == .cloudPC)
    #expect(cloud.rdpFileURL?.absoluteString == "https://rdweb.wvd.microsoft.com/api/arm/feed/cpc-1/rdp")
    let app = try #require(items.first { $0.id == "app-1" })
    #expect(app.kind == .remoteApp)
}

@Test func feedDiscoveryReadsAnAtomWorkspaceURL() throws {
    let feeds = try WorkspaceFeed.parseDiscovery(atomDiscovery)
    #expect(feeds.count == 1)
    #expect(feeds[0].name == "Contoso workspace")
    #expect(feeds[0].feedURL.absoluteString == "https://rdweb.wvd.microsoft.com/api/arm/feed/ws-1")
}

private let tenantFeeds = """
<?xml version="1.0" encoding="utf-8"?>
<TenantFeedURLs>
  <TenantFeedURL FeedURL="https://rdweb.wvd.microsoft.com/api/arm/feed/ws-1" TenantId="t1" TenantDisplayName="Contoso"/>
</TenantFeedURLs>
""".data(using: .utf8)!

private let nestedResources = """
<?xml version="1.0" encoding="utf-8"?>
<ResourceCollection>
  <Publisher Name="Contoso IT">
    <Resources>
      <Resource ID="r1" Title="Finance Desktop" Type="Desktop">
        <HostingTerminalServers>
          <HostingTerminalServer>
            <ResourceFile URL="https://rdweb.wvd.microsoft.com/r1.rdp"/>
          </HostingTerminalServer>
        </HostingTerminalServers>
      </Resource>
      <Resource ID="r2" Title="Ops Console" Type="RemoteApp">
        <HostingTerminalServers>
          <HostingTerminalServer>
            <ResourceFile URL="https://rdweb.wvd.microsoft.com/r2.rdp"/>
          </HostingTerminalServer>
        </HostingTerminalServers>
      </Resource>
    </Resources>
  </Publisher>
</ResourceCollection>
""".data(using: .utf8)!

@Test func discoveryReadsTenantFeedURLAttributes() throws {
    let feeds = try WorkspaceFeed.parseDiscovery(tenantFeeds)
    #expect(feeds.count == 1)
    #expect(feeds[0].name == "Contoso")
    #expect(feeds[0].feedURL.absoluteString == "https://rdweb.wvd.microsoft.com/api/arm/feed/ws-1")
}

@Test func resourcesReadTheNestedRdpFileURL() throws {
    let items = try WorkspaceFeed.parseResources(nestedResources)
    #expect(items.count == 2)
    let desktop = try #require(items.first { $0.id == "r1" })
    #expect(desktop.kind == .desktop)
    #expect(desktop.name == "Finance Desktop")
    #expect(desktop.rdpFileURL?.absoluteString == "https://rdweb.wvd.microsoft.com/r1.rdp")
    let app = try #require(items.first { $0.id == "r2" })
    #expect(app.kind == .remoteApp)
}

@Test func resourceCollectionDiscoveryPointsBackAtTheSameFeed() throws {
    let feeds = try WorkspaceFeed.parseDiscovery(workspaceXML)
    #expect(feeds.count == 1)
    #expect(feeds[0].name == "Contoso")
    #expect(feeds[0].id == "tenant-1")
    #expect(feeds[0].feedURL == WorkspaceFeed.discoveryURL)
}

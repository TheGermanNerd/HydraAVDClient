import Foundation
import Testing
@testable import HydraRdpCore

@Test func publishedNameFallsBackWhenBlank() {
    let config = PublishedPCConfiguration(id: "desk-1", name: "  ")
    #expect(config.resolvedName(fallback: "SessionDesktop") == "SessionDesktop")
}

@Test func publishedConfigurationRoundTrip() throws {
    let config = PublishedPCConfiguration(
        id: "desk-1",
        name: "SessionDesktop",
        credentials: .signedInAccount,
        useCustomSettings: true,
        displayMode: .fullscreen
    )
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(PublishedPCConfiguration.self, from: data)
    #expect(decoded == config)
}

@Test func preferencesStorePublishedPCs() {
    let suite = "PublishedPCTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let preferences = AppPreferences(defaults: defaults)
    preferences.publishedPCs = [PublishedPCConfiguration(id: "a", name: "One")]
    let reloaded = AppPreferences(defaults: defaults)
    #expect(reloaded.publishedPC(id: "a") == preferences.publishedPCs.first)
    defaults.removePersistentDomain(forName: suite)
}

@Test func generalConnectionDefaultsMatchWindowsApp() {
    let suite = "GeneralSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let preferences = AppPreferences(defaults: defaults)
    #expect(preferences.useHTTPProxy == false)
    #expect(preferences.useUDP == true)
    #expect(preferences.teamsOptimizations == true)
    #expect(preferences.webAuthnRedirection == false)
    #expect(preferences.shareDiagnostics == false)

    preferences.useHTTPProxy = true
    preferences.useUDP = false
    let reloaded = AppPreferences(defaults: defaults)
    #expect(reloaded.useHTTPProxy == true)
    #expect(reloaded.useUDP == false)
    #expect(reloaded.teamsOptimizations == true)
    #expect(reloaded.webAuthnRedirection == false)
    #expect(reloaded.shareDiagnostics == false)
    defaults.removePersistentDomain(forName: suite)
}

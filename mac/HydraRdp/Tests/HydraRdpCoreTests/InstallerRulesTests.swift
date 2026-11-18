import Foundation
import Security
import Testing
@testable import HydraRdpCore

@Test func licenseAcceptanceFollowsTheBundledNoticesVersion() {
    #expect(InstallerRules.needsLicenseAcceptance(acceptedVersion: "", currentVersion: "abc"))
    #expect(InstallerRules.needsLicenseAcceptance(acceptedVersion: "old", currentVersion: "abc"))
    #expect(!InstallerRules.needsLicenseAcceptance(acceptedVersion: "abc", currentVersion: "abc"))
    #expect(InstallerRules.needsLicenseAcceptance(acceptedVersion: "abc", currentVersion: ""))
}

@Test func setupStaysUpUntilTheLicenseAndClientKeyAreStored() {
    #expect(InstallerRules.needsSetup(licenseAcceptedVersion: "", licenseCurrentVersion: "abc", clientKey: ""))
    #expect(InstallerRules.needsSetup(licenseAcceptedVersion: "abc", licenseCurrentVersion: "abc", clientKey: "  "))
    #expect(!InstallerRules.needsSetup(licenseAcceptedVersion: "abc", licenseCurrentVersion: "abc", clientKey: "secret"))
}

@Test func clientKeyRequiresTheSameNonEmptyValue() {
    #expect(!InstallerRules.clientKeyConfirmed("", confirmation: ""))
    #expect(!InstallerRules.clientKeyConfirmed("secret", confirmation: "other"))
    #expect(!InstallerRules.clientKeyConfirmed("   ", confirmation: "   "))
    #expect(InstallerRules.clientKeyConfirmed(" secret ", confirmation: "secret"))
    #expect(InstallerRules.normalizedClientKey(" secret ", confirmation: "secret") == "secret")
}

@Test func workspaceFeedAllowsBlankOrHttp() {
    #expect(InstallerRules.workspaceFeedURLIsValid(""))
    #expect(InstallerRules.workspaceFeedURLIsValid("   "))
    #expect(InstallerRules.workspaceFeedURLIsValid("https://workspace.example.com/feed"))
    #expect(InstallerRules.workspaceFeedURLIsValid("http://10.0.0.8/rdweb"))
    #expect(!InstallerRules.workspaceFeedURLIsValid("ftp://files.example.com"))
    #expect(!InstallerRules.workspaceFeedURLIsValid("workspace.example.com"))
}

@Test func noticesVersionChangesWhenTheTextChanges() {
    let first = InstallerRules.noticesVersion(parts: ["Apache", "MIT"])
    let second = InstallerRules.noticesVersion(parts: ["Apache", "MIT"])
    let third = InstallerRules.noticesVersion(parts: ["Apache", "BSD"])
    #expect(first == second)
    #expect(first != third)
    #expect(first.count == 64)
}

@Test func installedAppPathIsTheApplicationsCopy() {
    #expect(InstallerRules.isRunningInstalledApp(bundlePath: "/Applications/Hydra AVD Client.app"))
    #expect(!InstallerRules.isRunningInstalledApp(bundlePath: "/Users/me/Hydra AVD Client.app"))
}

@Test func savedDesktopEncodingOmitsPasswords() throws {
    let desktop = SavedDesktop(name: "Finance", host: "pc.example.com", user: "ada")
    let data = try JSONEncoder().encode(desktop)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.localizedCaseInsensitiveContains("password"))
    #expect(!text.contains("client-key"))
    #expect(text.contains("ada"))
}

@Test func keychainStoresSecretsOnThisMacOnly() throws {
    let account = "installer-rules-\(UUID().uuidString)"
    defer { KeychainStore.remove(account: account) }
    try KeychainStore.set("local-secret", account: account)
    #expect(KeychainStore.string(account: account) == "local-secret")

    let synced = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KeychainStore.service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: true,
        kSecReturnData as String: true
    ] as CFDictionary, nil)
    #expect(synced != errSecSuccess)

    var item: CFTypeRef?
    let local = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KeychainStore.service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
        kSecReturnData as String: true
    ] as CFDictionary, &item)
    #expect(local == errSecSuccess)
    #expect(String(data: item as? Data ?? Data(), encoding: .utf8) == "local-secret")
}

@Test func publishedPCEncodingOmitsPasswords() throws {
    let configuration = PublishedPCConfiguration(id: "resource", name: "Excel")
    let data = try JSONEncoder().encode(configuration)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.localizedCaseInsensitiveContains("password"))
    #expect(!text.contains("token"))
}

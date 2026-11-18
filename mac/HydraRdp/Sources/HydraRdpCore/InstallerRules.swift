import CryptoKit
import Foundation

/// Checks for the first-launch installer. Secrets are not stored here.
public enum InstallerRules {
    public static let installedAppPath = "/Applications/Hydra AVD Client.app"

    public static func needsLicenseAcceptance(acceptedVersion: String, currentVersion: String) -> Bool {
        currentVersion.isEmpty || acceptedVersion != currentVersion
    }

    public static func needsSetup(licenseAcceptedVersion: String, licenseCurrentVersion: String, clientKey: String) -> Bool {
        needsLicenseAcceptance(acceptedVersion: licenseAcceptedVersion, currentVersion: licenseCurrentVersion)
            || clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Both fields must contain the same non-empty key after trimming.
    public static func clientKeyConfirmed(_ key: String, confirmation: String) -> Bool {
        normalizedClientKey(key, confirmation: confirmation) != nil
    }

    public static func normalizedClientKey(_ key: String, confirmation: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = confirmation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == confirmed else { return nil }
        return trimmed
    }

    /// A blank feed is allowed. Any other value must use http or https, matching workspace setup.
    public static func workspaceFeedURLIsValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func isRunningInstalledApp(bundlePath: String) -> Bool {
        URL(fileURLWithPath: bundlePath).standardizedFileURL.path == installedAppPath
    }

    public static func noticesVersion(parts: [String]) -> String {
        let data = Data(parts.joined(separator: "\n").utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

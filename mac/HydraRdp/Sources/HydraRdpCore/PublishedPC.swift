import Foundation

public enum PublishedCredentialMode: String, Codable, Equatable, CaseIterable, Identifiable {
    /// Leave the published sign-in alone until the PC asks for one.
    case askWhenRequired
    /// Use the signed-in work or school account when the feed does not name a user.
    case signedInAccount

    public var id: String { rawValue }
}

/// Local name and sign-in choices for one published desktop or remote app.
public struct PublishedPCConfiguration: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var credentials: PublishedCredentialMode
    public var useCustomSettings: Bool
    public var displayMode: SessionDisplayMode

    public init(
        id: String,
        name: String,
        credentials: PublishedCredentialMode = .askWhenRequired,
        useCustomSettings: Bool = false,
        displayMode: SessionDisplayMode = .windowed
    ) {
        self.id = id
        self.name = name
        self.credentials = credentials
        self.useCustomSettings = useCustomSettings
        self.displayMode = displayMode
    }

    public func resolvedName(fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

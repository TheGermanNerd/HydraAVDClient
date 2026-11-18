import Foundation

public enum SessionDisplayMode: String, Codable, CaseIterable, Identifiable {
    case windowed
    case fullscreen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .windowed: return "Window"
        case .fullscreen: return "Full screen"
        }
    }
}

/// A saved direct desktop. Passwords are not part of this value.
public struct SavedDesktop: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var user: String
    public var gatewayHost: String
    public var gatewayUser: String
    public var displayMode: SessionDisplayMode
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String,
        gatewayHost: String = "",
        gatewayUser: String = "",
        displayMode: SessionDisplayMode = .windowed,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.gatewayHost = gatewayHost
        self.gatewayUser = gatewayUser
        self.displayMode = displayMode
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, user, gatewayHost, gatewayUser, displayMode, isFavorite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        user = try container.decode(String.self, forKey: .user)
        gatewayHost = try container.decodeIfPresent(String.self, forKey: .gatewayHost) ?? ""
        gatewayUser = try container.decodeIfPresent(String.self, forKey: .gatewayUser) ?? ""
        displayMode = try container.decodeIfPresent(SessionDisplayMode.self, forKey: .displayMode) ?? .windowed
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(user, forKey: .user)
        try container.encode(gatewayHost, forKey: .gatewayHost)
        try container.encode(gatewayUser, forKey: .gatewayUser)
        try container.encode(displayMode, forKey: .displayMode)
        try container.encode(isFavorite, forKey: .isFavorite)
    }

    public var listTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }
}

public enum DesktopStore {
    private static let key = "savedDesktops"

    public static func load(defaults: UserDefaults = AppPreferences.suite()) -> [SavedDesktop] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedDesktop].self, from: data)) ?? []
    }

    public static func save(_ desktops: [SavedDesktop], defaults: UserDefaults = AppPreferences.suite()) {
        if let data = try? JSONEncoder().encode(desktops) {
            defaults.set(data, forKey: key)
        }
    }
}

public extension AppPreferences {
    static func suite() -> UserDefaults {
        UserDefaults(suiteName: AppPreferences.suiteName) ?? .standard
    }
}

public enum DesktopSecrets {
    public static func passwordAccount(_ id: UUID) -> String { "desktop-password.\(id.uuidString)" }
    public static func gatewayPasswordAccount(_ id: UUID) -> String { "desktop-gateway-password.\(id.uuidString)" }
}

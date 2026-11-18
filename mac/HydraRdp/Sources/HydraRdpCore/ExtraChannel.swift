import Foundation
import HydraChannelProtocol

public enum ExtraChannelKind: String, Codable, CaseIterable, Identifiable {
    case echo
    case library

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .echo: return "Echo (built in)"
        case .library: return "DVCPluginEntry library"
        }
    }
}

public struct ExtraChannel: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ExtraChannelKind
    public var libraryPath: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ExtraChannelKind,
        libraryPath: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.libraryPath = libraryPath
        self.enabled = enabled
    }

    public var isUsable: Bool {
        guard enabled else { return false }
        guard Self.isValidName(name) else { return false }
        if kind == .library {
            return !libraryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...127).contains(trimmed.count) else { return false }
        guard trimmed != HydraChannelProtocol.channelName else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            if scalar.value < 33 || scalar.value > 126 { return false }
            return scalar != "\t" && scalar != ":" && scalar != ","
        }
    }
}

public enum ExtraChannelStore {
    private static let key = "extraChannels"

    public static func load(defaults: UserDefaults = AppPreferences.suite()) -> [ExtraChannel] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ExtraChannel].self, from: data)) ?? []
    }

    public static func save(_ channels: [ExtraChannel], defaults: UserDefaults = AppPreferences.suite()) {
        if let data = try? JSONEncoder().encode(channels) {
            defaults.set(data, forKey: key)
        }
    }
}

public enum HydraPaths {
    public static var channelsDirectory: URL {
        let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("ITProCloud/HydraRdp/Channels", isDirectory: true)
    }

    public static func ensureChannelsDirectory() -> URL {
        let url = channelsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func librariesInChannelsFolder() -> [URL] {
        let folder = ensureChannelsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { ["dylib", "so"].contains($0.pathExtension.lowercased()) }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}

public enum ClientKeyStore {
    public static let account = "client-key"

    public static func load() -> String {
        KeychainStore.string(account: account) ?? ""
    }

    public static func save(_ value: String) throws {
        if value.isEmpty {
            KeychainStore.remove(account: account)
        } else {
            try KeychainStore.set(value, account: account)
        }
    }
}

public enum EntraSecretStore {
    public static let accessAccount = "entra-access-token"
    public static let refreshAccount = "entra-refresh-token"

    public static func save(accessToken: String, refreshToken: String?) throws {
        try KeychainStore.set(accessToken, account: accessAccount)
        if let refreshToken, !refreshToken.isEmpty {
            try KeychainStore.set(refreshToken, account: refreshAccount)
        }
    }

    public static func accessToken() -> String? {
        let value = KeychainStore.string(account: accessAccount)
        return (value?.isEmpty == false) ? value : nil
    }

    public static func refreshToken() -> String? {
        let value = KeychainStore.string(account: refreshAccount)
        return (value?.isEmpty == false) ? value : nil
    }

    public static func clear() {
        KeychainStore.remove(account: accessAccount)
        KeychainStore.remove(account: refreshAccount)
    }
}

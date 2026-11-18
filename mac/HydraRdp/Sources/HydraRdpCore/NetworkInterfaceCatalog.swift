import Foundation
import HydraAgentCore

public struct ListedNetworkInterface: Equatable, Sendable, Identifiable {
    public var name: String
    public var ipv4Address: String?

    public var id: String { name }

    public init(name: String, ipv4Address: String?) {
        self.name = name
        self.ipv4Address = ipv4Address
    }

    public var menuTitle: String {
        if let ipv4Address, !ipv4Address.isEmpty {
            return "\(name) — \(ipv4Address)"
        }
        return name
    }
}

public enum NetworkInterfaceCatalog {
    public static func current() -> [ListedNetworkInterface] {
        NetworkInterfaces.current().map {
            ListedNetworkInterface(name: $0.name, ipv4Address: $0.ipv4Address)
        }
    }
}

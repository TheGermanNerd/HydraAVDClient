import Darwin
import Foundation

enum SoftwareCollector {
    static func collect() -> SoftwareSection {
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
        var applications = apps(in: root)
        let utilities = root.appendingPathComponent("Utilities", isDirectory: true)
        applications.append(contentsOf: apps(in: utilities))
        applications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return SoftwareSection(applications: applications)
    }

    private static func apps(in directory: URL) -> [ApplicationInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension == "app" }.map(readApp)
    }

    private static func readApp(_ url: URL) -> ApplicationInfo {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        let dict = NSDictionary(contentsOf: plist)
        let name = (dict?["CFBundleDisplayName"] as? String)
            ?? (dict?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = dict?["CFBundleShortVersionString"] as? String
        return ApplicationInfo(name: name, version: version)
    }
}

public struct NetworkInterfaceChoice: Equatable, Sendable, Identifiable {
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

public enum NetworkInterfaces {
    public static func current() -> [NetworkInterfaceChoice] {
        NetworkCollector.choices()
    }

    /// BSD interface names only. Rejects spaces, shell metacharacters, and empty strings.
    public static func isValidName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.range(of: #"^[A-Za-z][A-Za-z0-9]{0,15}$"#, options: .regularExpression) != nil
    }
}

enum NetworkCollector {
    static func choices() -> [NetworkInterfaceChoice] {
        var order: [String] = []
        var addresses: [String: String] = [:]
        for interface in interfaces() {
            if !order.contains(interface.name) {
                order.append(interface.name)
            }
            if interface.family == "ipv4", addresses[interface.name] == nil {
                addresses[interface.name] = interface.address
            }
        }
        return order.map { NetworkInterfaceChoice(name: $0, ipv4Address: addresses[$0]) }
    }

    static func interfaces() -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [InterfaceInfo] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            if (flags & IFF_LOOPBACK) != 0 { continue }
            guard let address = interface.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            let isIPv4 = family == UInt8(AF_INET)
            let isIPv6 = family == UInt8(AF_INET6)
            guard isIPv4 || isIPv6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(isIPv4 ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            var ip = String(cString: host)
            if let percent = ip.firstIndex(of: "%") {
                ip = String(ip[..<percent])
            }
            if isIPv6 && ip.lowercased().hasPrefix("fe80:") { continue }
            let name = String(cString: interface.pointee.ifa_name)
            results.append(InterfaceInfo(name: name, address: ip, family: isIPv4 ? "ipv4" : "ipv6"))
        }
        return results.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.family < rhs.family }
            return lhs.name < rhs.name
        }
    }

    static func defaultGateway(interfaceName: String? = nil) -> GatewayInfo? {
        var arguments = ["-n", "get"]
        if let interfaceName {
            arguments.append(contentsOf: ["-ifscope", interfaceName])
        }
        arguments.append("default")
        let output = ProcessRunner.run(
            executable: "/sbin/route",
            arguments: arguments,
            timeout: 5
        )
        guard var gateway = RouteParser.gateway(from: output.text) else { return nil }
        if let interfaceName {
            gateway.interfaceName = interfaceName
        }
        return gateway
    }

    static func ping(target: String, enabled: Bool, interfaceName: String? = nil) -> (PingSample, String?) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled else {
            return (PingSample(target: trimmed, reachable: false, latencyMs: nil, skipped: true), nil)
        }
        guard PingParser.isValidTarget(trimmed) else {
            return (
                PingSample(target: trimmed, reachable: false, latencyMs: nil, skipped: true),
                "Ping target is not a hostname or IP address."
            )
        }
        var arguments = ["-c", "1", "-W", "2000"]
        if let interfaceName {
            arguments.insert(contentsOf: ["-b", interfaceName], at: 0)
        }
        arguments.append(trimmed)
        let output = ProcessRunner.run(
            executable: "/sbin/ping",
            arguments: arguments,
            timeout: 5
        )
        if output.text.lowercased().contains("operation not permitted") {
            return (
                PingSample(target: trimmed, reachable: false, latencyMs: nil, skipped: false),
                "Ping to \(trimmed) was not permitted."
            )
        }
        let parsed = PingParser.parse(output.text)
        return (
            PingSample(target: trimmed, reachable: parsed.reachable, latencyMs: parsed.latencyMs, skipped: false),
            nil
        )
    }
}

enum SecurityCollector {
    static func collect() -> (SecuritySection, [String]) {
        var errors: [String] = []
        let fileVaultOutput = ProcessRunner.run(executable: "/usr/bin/fdesetup", arguments: ["status"], timeout: 8)
        let fileVault = SecurityStatusParser.fileVaultEnabled(from: fileVaultOutput.text)
        if fileVault == nil {
            errors.append("FileVault status was not available.")
        }
        let firewallOutput = ProcessRunner.run(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getglobalstate"],
            timeout: 8
        )
        let firewall = SecurityStatusParser.firewallEnabled(from: firewallOutput.text)
        if firewall == nil {
            errors.append("Firewall status was not available.")
        }
        return (SecuritySection(fileVaultEnabled: fileVault, firewallEnabled: firewall), errors)
    }
}

enum RouteParser {
    static func gateway(from output: String) -> GatewayInfo? {
        var address: String?
        var interfaceName: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            if parts[0] == "gateway:" { address = parts[1] }
            if parts[0] == "interface:" { interfaceName = parts[1] }
        }
        guard let address, !address.isEmpty, !address.hasPrefix("link#") else { return nil }
        return GatewayInfo(address: address, interfaceName: interfaceName)
    }
}

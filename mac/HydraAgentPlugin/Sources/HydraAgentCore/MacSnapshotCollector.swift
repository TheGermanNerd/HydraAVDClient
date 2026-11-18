import Foundation

/// Collects the Mac client snapshot used by the menu-bar companion and by Hydra AVD Client.
/// Sensitive fields stay off unless `showSensitiveData` is true.
public final class MacSnapshotCollector: @unchecked Sendable {
    private let locationCollector = LocationCollector()
    private let lock = NSLock()
    private var gpuNames: [String] = []
    private var gpuFetchedAt = Date.distantPast
    private var publicIPCache: PublicIPCache?
    private let cacheLifetime: TimeInterval = 60

    public init() {}

    public func makeSnapshot(
        pingEnabled: Bool,
        pingTarget: String,
        networkInterface: String = "",
        showSensitiveData: Bool,
        displays: [DisplayInfo],
        now: Date = Date()
    ) async -> ClientSnapshot {
        var errors: [String] = []
        let gpus = gpuNames(now: now, errors: &errors)
        let deviceResult = DeviceCollector.collect(displays: displays, gpus: gpus)
        errors.append(contentsOf: deviceResult.1)

        let software = SoftwareCollector.collect()
        let network = await network(
            pingEnabled: pingEnabled,
            pingTarget: pingTarget,
            networkInterface: networkInterface,
            now: now,
            errors: &errors
        )
        let securityResult = SecurityCollector.collect()
        errors.append(contentsOf: securityResult.1)

        let sensitive: SensitiveSection?
        if showSensitiveData {
            let fix = await locationCollector.requestFix()
            if let fix {
                sensitive = SensitiveCollector.current(
                    location: LocationFix(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
                )
            } else {
                errors.append("Location was not available.")
                sensitive = SensitiveCollector.current(location: nil)
            }
        } else {
            sensitive = nil
        }

        return SnapshotAssembly.make(
            collectedAtUtc: now,
            device: deviceResult.0,
            software: software,
            network: network,
            security: securityResult.0,
            sensitive: sensitive,
            errors: errors,
            showSensitiveData: showSensitiveData
        )
    }

    private func gpuNames(now: Date, errors: inout [String]) -> [String] {
        lock.lock()
        if now.timeIntervalSince(gpuFetchedAt) < cacheLifetime, !gpuNames.isEmpty {
            let cached = gpuNames
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let loaded = DeviceCollector.loadGPUNames() {
            lock.lock()
            gpuNames = loaded
            gpuFetchedAt = now
            lock.unlock()
            return loaded
        }
        lock.lock()
        let cached = gpuNames
        lock.unlock()
        if cached.isEmpty {
            errors.append("GPU information was not available.")
        }
        return cached
    }

    private func network(
        pingEnabled: Bool,
        pingTarget: String,
        networkInterface: String,
        now: Date,
        errors: inout [String]
    ) async -> NetworkSection {
        let interfaces = NetworkCollector.interfaces()
        let requested = networkInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requested.isEmpty {
            let present = NetworkInterfaces.isValidName(requested) && interfaces.contains { $0.name == requested }
            if !present {
                errors.append("Interface \(requested) is not available.")
                return NetworkSection(
                    interfaces: interfaces,
                    gateway: nil,
                    internetPing: nil,
                    gatewayPing: nil,
                    publicIp: nil,
                    boundInterface: NetworkInterfaces.isValidName(requested) ? requested : nil
                )
            }
        }

        let bound = requested.isEmpty ? nil : requested
        let gateway = NetworkCollector.defaultGateway(interfaceName: bound)
        let internet = NetworkCollector.ping(target: pingTarget, enabled: pingEnabled, interfaceName: bound)
        if let error = internet.1 {
            errors.append(error)
        }

        var gatewayPing: PingSample?
        if pingEnabled, let gateway, PingParser.isValidTarget(gateway.address) {
            let sample = NetworkCollector.ping(target: gateway.address, enabled: true, interfaceName: bound)
            gatewayPing = sample.0
            if let error = sample.1 {
                errors.append(error)
            }
        }

        let publicIP = await publicIPAddress(now: now, interfaceName: bound)
        if publicIP == nil {
            errors.append("Public IP lookup failed.")
        }

        return NetworkSection(
            interfaces: interfaces,
            gateway: gateway,
            internetPing: internet.0,
            gatewayPing: gatewayPing,
            publicIp: publicIP,
            boundInterface: bound
        )
    }

    private func publicIPAddress(now: Date, interfaceName: String?) async -> String? {
        if let cached = cachedPublicIPIfFresh(now: now, interfaceName: interfaceName) {
            return cached
        }
        let fetched: String?
        if let interfaceName {
            fetched = publicIPBound(to: interfaceName)
        } else {
            fetched = await publicIPFromSession()
        }
        if let fetched {
            storePublicIP(fetched, interfaceName: interfaceName, now: now)
            return fetched
        }
        return cachedPublicIP(interfaceName: interfaceName)
    }

    private func publicIPFromSession() async -> String? {
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return Self.publicIP(in: data)
        } catch {
            CollectorDiagnostics.recordError?("Public IP lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func publicIPBound(to interfaceName: String) -> String? {
        let output = ProcessRunner.run(
            executable: "/usr/bin/curl",
            arguments: ["-s", "--interface", interfaceName, "--max-time", "5", "https://api.ipify.org?format=json"],
            timeout: 8
        )
        guard let ip = Self.publicIP(in: output.text) else {
            CollectorDiagnostics.recordError?("Public IP lookup failed.")
            return nil
        }
        return ip
    }

    private static func publicIP(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(IPResponse.self, from: data) else { return nil }
        let ip = body.ip.trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? nil : ip
    }

    private static func publicIP(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end,
              let data = String(text[start...end]).data(using: .utf8) else {
            return nil
        }
        return publicIP(in: data)
    }

    private func cachedPublicIPIfFresh(now: Date, interfaceName: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let publicIPCache,
              publicIPCache.interfaceName == interfaceName,
              now.timeIntervalSince(publicIPCache.fetchedAt) < cacheLifetime else {
            return nil
        }
        return publicIPCache.address
    }

    private func storePublicIP(_ ip: String, interfaceName: String?, now: Date) {
        lock.lock()
        publicIPCache = PublicIPCache(interfaceName: interfaceName, address: ip, fetchedAt: now)
        lock.unlock()
    }

    private func cachedPublicIP(interfaceName: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let publicIPCache, publicIPCache.interfaceName == interfaceName else { return nil }
        return publicIPCache.address
    }
}

private struct PublicIPCache {
    var interfaceName: String?
    var address: String
    var fetchedAt: Date
}

private struct IPResponse: Decodable {
    var ip: String
}

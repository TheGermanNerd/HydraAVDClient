import Darwin
import Foundation
import HydraAgentCore

/// Maps a Mac snapshot into the PascalCase models `System.Text.Json` writes
/// for the Windows plugin (`WindowsDiagnostic.Models`). The Hydra agent
/// binds its endpoint view to those names.
enum EndpointInventory {
    static func systemInventory(_ snapshot: ClientSnapshot, cpuPercent: Double) -> String {
        let stamp = DotNetDateTimeOffset.string(snapshot.collectedAtUtc)
        let adapters = adapters(from: snapshot)
        let primary = primaryIPv4(in: adapters, boundInterface: snapshot.network?.boundInterface)
        let device = snapshot.device
        let body: [String: Any] = [
            "CollectedAtUtc": stamp,
            "OperatingSystem": operatingSystem(snapshot, primaryIPv4: primary),
            "Bios": bios(device),
            "Cpus": cpus(device, cpuPercent: cpuPercent),
            "Memory": memory(device),
            "Drives": drives(device),
            "PhysicalDisks": physicalDisks(snapshot),
            "InstalledApplications": applications(snapshot),
            "NetworkAdapters": adapters.map { $0.json() },
            "Gpus": gpus(device),
            "Battery": battery(device),
            "Monitors": monitors(device),
            "UserIdentity": userIdentity(snapshot),
            "WindowsApp": unavailable(),
            "InstalledUpdates": [Any](),
            "Firewall": firewall(snapshot),
            "Antivirus": unavailable(),
            "DeviceCompliance": unavailable(),
            "Location": locationValue(snapshot, stamp: stamp),
            "AllErrors": diagnosticErrors(snapshot.errors ?? [], collector: "HydraAgentMac")
        ]
        return json(body)
    }

    static func location(_ snapshot: ClientSnapshot) -> String {
        let stamp = DotNetDateTimeOffset.string(snapshot.collectedAtUtc)
        return json(locationValue(snapshot, stamp: stamp))
    }

    static func network(
        _ snapshot: ClientSnapshot,
        parameter: String,
        trace: TraceRouteResult? = nil
    ) -> String {
        let stamp = DotNetDateTimeOffset.string(snapshot.collectedAtUtc)
        let adapters = adapters(from: snapshot)
        let probe = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
        var bandwidthErrors: [[String: Any]] = []
        if !probe.isEmpty {
            bandwidthErrors = diagnosticErrors(["Bandwidth was not measured."], collector: "Bandwidth")
        }
        let body: [String: Any] = [
            "CollectedAtUtc": stamp,
            "ActiveConnection": activeConnection(adapters, snapshot: snapshot),
            "GatewayLatency": pingResult(snapshot.network?.gatewayPing, collector: "Gateway"),
            "InternetLatency": pingResult(snapshot.network?.internetPing, collector: "Internet"),
            "TraceRoute": traceRoute(snapshot.network?.internetPing, trace: trace),
            "Provider": provider(snapshot),
            "Bandwidth": collection(NSNull(), available: false, errors: bandwidthErrors),
            "LatencyUnderLoad": unavailable()
        ]
        return json(body)
    }

    static func performance(_ snapshot: ClientSnapshot, cpuPercent: Double) -> String {
        let totals = memoryTotals(snapshot.device)
        return json([performanceSample(
            at: snapshot.collectedAtUtc,
            cpuPercent: cpuPercent,
            totalMemoryBytes: totals.total,
            usedMemoryBytes: totals.used,
            disks: [],
            networks: [],
            latency: latency(snapshot)
        )])
    }

    /// One `PerformanceSample`. Disk and network arrays are the series the
    /// endpoint graphs draw; an empty array leaves that graph blank.
    static func performanceSample(
        at date: Date,
        cpuPercent: Double,
        totalMemoryBytes: Int64,
        usedMemoryBytes: Int64,
        disks: [[String: Any]],
        networks: [[String: Any]],
        latency: [String: Any]
    ) -> [String: Any] {
        let total = max(Int64(0), totalMemoryBytes)
        let used = min(total, max(Int64(0), usedMemoryBytes))
        let available = total - used
        let percent = total > 0 ? Double(used) / Double(total) * 100 : 0
        return [
            "Timestamp": DotNetDateTimeOffset.string(date),
            "Cpu": ["UtilizationPercentage": cpuPercent],
            "Memory": [
                "TotalBytes": total,
                "AvailableBytes": available,
                "UsedBytes": used,
                "UsedPercentage": percent
            ],
            "Disks": disks,
            "Networks": networks,
            "Latency": latency
        ]
    }

    static func hostMemory() -> (total: Int64, used: Int64) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let read = sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0
        let totalBytes: Int64 = read && total <= UInt64(Int64.max) ? Int64(total) : 0
        let used = min(totalBytes, activeUsedMemoryBytes())
        return (totalBytes, used)
    }

    static func emptyLatency() -> [String: Any] {
        [
            "GatewayAddress": "",
            "GatewayReachable": false,
            "GatewayLatencyMs": NSNull(),
            "InternetTarget": "",
            "InternetReachable": false,
            "InternetLatencyMs": NSNull()
        ]
    }

    private static func operatingSystem(
        _ snapshot: ClientSnapshot,
        primaryIPv4: String?
    ) -> [String: Any] {
        guard let device = snapshot.device else {
            return unavailable()
        }
        var uptime: Any = NSNull()
        var boot: Any = NSNull()
        if let started = bootTime() {
            uptime = timeSpan(from: started, to: snapshot.collectedAtUtc)
            boot = DotNetDateTimeOffset.string(started)
        }
        let value: [String: Any] = [
            "ProductName": device.productName,
            "Version": device.productVersion,
            "Build": device.buildVersion,
            "Architecture": machineArchitecture,
            "MachineName": snapshot.sensitive?.computerName ?? "Mac",
            "PrimaryIPv4Address": primaryIPv4 ?? "",
            "UserName": snapshot.sensitive?.userName ?? "",
            "DomainOrWorkgroup": "",
            "IsDomainJoined": false,
            "Uptime": uptime,
            "BootTimeUtc": boot,
            "DotNetRuntimeVersion": NSNull(),
            "TimeZone": TimeZone.current.identifier,
            "Locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        ]
        return collection(value, available: true)
    }

    private static func bios(_ device: DeviceSection?) -> [String: Any] {
        guard let device else { return unavailable() }
        return collection([
            "SystemManufacturer": "Apple",
            "SystemModel": device.hardwareModel,
            "BiosManufacturer": "Apple",
            "BiosVersion": "",
            "BiosReleaseDate": ""
        ], available: true)
    }

    private static func cpus(_ device: DeviceSection?, cpuPercent: Double) -> [[String: Any]] {
        guard let device else { return [] }
        return [[
            "Name": device.cpuBrand,
            "Vendor": "",
            "PhysicalCores": NSNull(),
            "LogicalProcessors": device.cpuCount,
            "Architecture": machineArchitecture,
            "CurrentClockSpeedMhz": NSNull(),
            "MaxClockSpeedMhz": NSNull(),
            "UtilizationPercentage": cpuPercent
        ]]
    }

    private static func memory(_ device: DeviceSection?) -> [String: Any] {
        guard device != nil else { return unavailable() }
        let totals = memoryTotals(device)
        return collection([
            "TotalBytes": totals.total,
            "AvailableBytes": totals.available,
            "UsedBytes": totals.used,
            "UsedPercentage": totals.percent
        ], available: totals.total > 0)
    }

    private static func drives(_ device: DeviceSection?) -> [[String: Any]] {
        guard let device else { return [] }
        return device.disks.map { disk in
            let total = max(Int64(0), disk.totalBytes)
            let free = min(total, max(Int64(0), disk.availableBytes))
            let used = total - free
            var percent: Any = NSNull()
            if total > 0 {
                percent = Double(used) / Double(total) * 100
            }
            return [
                "Name": disk.mountPoint,
                "VolumeLabel": "",
                "DriveType": "Fixed",
                "FileSystem": disk.fileSystem ?? "",
                "TotalSizeBytes": total,
                "FreeSpaceBytes": free,
                "UsedSpaceBytes": used,
                "UsedPercentage": percent,
                "IsReady": true
            ]
        }
    }

    private static func physicalDisks(_ snapshot: ClientSnapshot) -> [[String: Any]] {
        guard let serial = snapshot.sensitive?.serialNumber, !serial.isEmpty else { return [] }
        return [[
            "DiskNumber": NSNull(),
            "Model": snapshot.device?.hardwareModel ?? "",
            "Manufacturer": "Apple",
            "SerialNumber": serial,
            "CapacityBytes": NSNull(),
            "MediaType": "System",
            "InterfaceType": ""
        ]]
    }

    private static func applications(_ snapshot: ClientSnapshot) -> [[String: Any]] {
        (snapshot.software?.applications ?? []).map { app in
            [
                "DisplayName": app.name,
                "DisplayVersion": app.version ?? "",
                "Publisher": "",
                "InstallLocation": "",
                "InstallDate": "",
                "Architecture": "",
                "UninstallString": ""
            ]
        }
    }

    private static func gpus(_ device: DeviceSection?) -> [[String: Any]] {
        (device?.gpus ?? []).map { name in
            [
                "Name": name,
                "Vendor": "",
                "DriverVersion": "",
                "VramBytes": NSNull()
            ]
        }
    }

    private static func battery(_ device: DeviceSection?) -> [String: Any] {
        guard let battery = device?.battery else { return unavailable() }
        let status: String
        if battery.present == false {
            status = "Not present"
        } else if battery.isCharging == true {
            status = "Charging"
        } else if battery.isCharging == false {
            status = "Discharging"
        } else {
            status = ""
        }
        return collection([
            "IsPresent": battery.present,
            "ChargePercentage": battery.chargePercentage ?? NSNull(),
            "IsCharging": (battery.isCharging ?? false) as Any,
            "Status": status
        ], available: true)
    }

    private static func monitors(_ device: DeviceSection?) -> [[String: Any]] {
        guard let device else { return [] }
        return device.displays.enumerated().map { index, display in
            [
                "DeviceName": "Display \(index + 1)",
                "FriendlyName": "",
                "IsPrimary": index == 0,
                "WidthPixels": display.width,
                "HeightPixels": display.height,
                "RefreshRateHz": NSNull()
            ]
        }
    }

    private static func userIdentity(_ snapshot: ClientSnapshot) -> [String: Any] {
        guard let name = snapshot.sensitive?.userName, !name.isEmpty else {
            return unavailable()
        }
        return collection([
            "UserName": name,
            "UserPrincipalName": NSNull(),
            "LogonTimeUtc": NSNull(),
            "DomainOrWorkgroup": "",
            "IsDomainJoined": false,
            "IsEntraJoined": false,
            "EntraTenantId": NSNull(),
            "EntraTenantDisplayName": NSNull(),
            "EntraIdpDomain": NSNull(),
            "EntraJoinedUserEmail": NSNull(),
            "IsHybridJoined": false
        ], available: true)
    }

    private static func firewall(_ snapshot: ClientSnapshot) -> [String: Any] {
        guard let enabled = snapshot.security?.firewallEnabled else {
            return unavailable()
        }
        return collection([
            "DomainProfileEnabled": enabled,
            "PrivateProfileEnabled": enabled,
            "PublicProfileEnabled": enabled,
            "ActiveProfiles": enabled ? ["macOS"] : [String]()
        ], available: true)
    }

    private static func locationValue(_ snapshot: ClientSnapshot, stamp: String) -> [String: Any] {
        guard let location = snapshot.sensitive?.location else {
            return unavailable()
        }
        return collection([
            "Latitude": location.latitude,
            "Longitude": location.longitude,
            "AccuracyMeters": NSNull(),
            "TimestampUtc": stamp
        ], available: true)
    }

    private static func activeConnection(_ adapters: [Adapter], snapshot: ClientSnapshot) -> [String: Any] {
        let adapter: Adapter?
        if let bound = snapshot.network?.boundInterface, !bound.isEmpty {
            adapter = adapters.first { $0.name == bound }
        } else {
            adapter = adapters.first { !$0.isLoopback && !$0.ipv4.isEmpty } ?? adapters.first
        }
        guard let adapter else {
            return unavailable()
        }
        let gateway = snapshot.network?.gateway
        let gatewayAddress = gateway?.interfaceName == nil || gateway?.interfaceName == adapter.name
            ? (gateway?.address ?? "")
            : ""
        return collection([
            "InterfaceName": adapter.name,
            "InterfaceType": adapter.interfaceType,
            "IPv4Address": adapter.ipv4.first ?? "",
            "IPv6Address": adapter.ipv6.first ?? "",
            "Gateway": gatewayAddress,
            "DnsServers": [String](),
            "LinkSpeedBps": NSNull(),
            "WifiSignalQualityPercent": NSNull()
        ], available: true)
    }

    private static func provider(_ snapshot: ClientSnapshot) -> [String: Any] {
        guard let address = snapshot.network?.publicIp, !address.isEmpty else {
            return unavailable()
        }
        return collection([
            "PublicIp": address,
            "Provider": NSNull(),
            "Asn": NSNull(),
            "Organization": NSNull(),
            "City": NSNull(),
            "Region": NSNull(),
            "Country": NSNull()
        ], available: true)
    }

    /// `TraceRoute` uses the internet ping target. A missing or skipped ping
    /// stays unavailable with the same message as `InternetLatency`.
    private static func traceRoute(_ sample: PingSample?, trace: TraceRouteResult?) -> [String: Any] {
        guard let sample else {
            return collection(
                NSNull(),
                available: false,
                errors: diagnosticErrors(["No ping sample was collected."], collector: "TraceRoute")
            )
        }
        if sample.skipped {
            return collection(
                NSNull(),
                available: false,
                errors: diagnosticErrors(["Ping was skipped."], collector: "TraceRoute")
            )
        }
        let target = sample.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            return collection(
                NSNull(),
                available: false,
                errors: diagnosticErrors(["No target specified."], collector: "TraceRoute")
            )
        }
        guard let trace, !trace.hops.isEmpty else {
            return collection(
                NSNull(),
                available: false,
                errors: diagnosticErrors(["Trace route to \(target) did not complete."], collector: "TraceRoute")
            )
        }
        let hops: [[String: Any]] = trace.hops.map { hop in
            [
                "HopNumber": hop.hopNumber,
                "Address": hop.address ?? NSNull(),
                "HostName": hop.hostName ?? NSNull(),
                "LatenciesMs": hop.latenciesMs,
                "TimedOut": hop.timedOut,
                "ReachedTarget": hop.reachedTarget
            ]
        }
        return collection([
            "Target": trace.target.isEmpty ? target : trace.target,
            "Hops": hops,
            "ReachedTarget": trace.reachedTarget
        ], available: true)
    }

    private static func pingResult(_ sample: PingSample?, collector: String) -> [String: Any] {
        guard let sample, !sample.skipped else {
            let message = sample == nil ? "No ping sample was collected." : "Ping was skipped."
            return collection(
                NSNull(),
                available: false,
                errors: diagnosticErrors([message], collector: collector)
            )
        }
        return collection(pingStatistics(sample), available: true)
    }

    private static func pingStatistics(_ sample: PingSample) -> [String: Any] {
        let received = sample.reachable ? 1 : 0
        var body: [String: Any] = [
            "Target": sample.target,
            "ResolvedAddress": NSNull(),
            "PacketsSent": 1,
            "PacketsReceived": received,
            "PacketLossPercentage": sample.reachable ? 0.0 : 100.0,
            "MinMs": NSNull(),
            "AvgMs": NSNull(),
            "MaxMs": NSNull(),
            "MedianMs": NSNull(),
            "FailureReason": sample.reachable ? NSNull() : "The target did not answer."
        ]
        if sample.reachable, let latency = sample.latencyMs {
            body["MinMs"] = latency
            body["AvgMs"] = latency
            body["MaxMs"] = latency
            body["MedianMs"] = latency
        }
        return body
    }

    static func latency(_ snapshot: ClientSnapshot) -> [String: Any] {
        let gateway = snapshot.network?.gatewayPing
        let internet = snapshot.network?.internetPing
        return [
            "GatewayAddress": snapshot.network?.gateway?.address ?? "",
            "GatewayReachable": gateway?.reachable == true && gateway?.skipped == false,
            "GatewayLatencyMs": latencyValue(gateway),
            "InternetTarget": internet?.target ?? "",
            "InternetReachable": internet?.reachable == true && internet?.skipped == false,
            "InternetLatencyMs": latencyValue(internet)
        ]
    }

    private static func latencyValue(_ sample: PingSample?) -> Any {
        guard let sample, sample.reachable, !sample.skipped, let latency = sample.latencyMs else {
            return NSNull()
        }
        return latency
    }

    private static func unavailable() -> [String: Any] {
        collection(NSNull(), available: false)
    }

    private static func collection(_ value: Any, available: Bool, errors: [[String: Any]] = []) -> [String: Any] {
        [
            "Value": value,
            "Errors": errors,
            "IsAvailable": available
        ]
    }

    private static func diagnosticErrors(_ messages: [String], collector: String) -> [[String: Any]] {
        messages.map { message in
            [
                "Collector": collector,
                "Metric": "",
                "Category": 4,
                "Message": message
            ]
        }
    }

    private struct MemoryTotals {
        var total: Int64
        var available: Int64
        var used: Int64
        var percent: Double
    }

    private static func memoryTotals(_ device: DeviceSection?) -> MemoryTotals {
        let total = max(Int64(0), device?.memoryBytes ?? 0)
        let used = total > 0 ? min(total, activeUsedMemoryBytes()) : 0
        let available = total - used
        let percent = total > 0 ? Double(used) / Double(total) * 100 : 0
        return MemoryTotals(total: total, available: available, used: used, percent: percent)
    }

    /// Bytes Activity Monitor reports as Memory Used: anonymous pages that are
    /// not purgeable, plus wired and compressed pages. Free pages, file cache,
    /// and speculative pages stay available. `speculative_count` is already
    /// included in `free_count`, so it must not be added again.
    static func activeUsedMemoryBytes(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: Int64
    ) -> Int64 {
        guard pageSize > 0 else { return 0 }
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let pages = app + wiredPages + compressedPages
        let bytes = pages * UInt64(pageSize)
        if bytes > UInt64(Int64.max) { return Int64.max }
        return Int64(bytes)
    }

    private static func activeUsedMemoryBytes() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return 0
        }
        return activeUsedMemoryBytes(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: Int64(pageSize)
        )
    }

    private static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    private static func timeSpan(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs = seconds % 60
        if days > 0 {
            return String(format: "%d.%02d:%02d:%02d", locale: Locale(identifier: "en_US_POSIX"), days, hours, minutes, secs)
        }
        return String(format: "%02d:%02d:%02d", locale: Locale(identifier: "en_US_POSIX"), hours, minutes, secs)
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return ""
        #endif
    }

    private struct Adapter {
        var name: String
        var ipv4: [String]
        var ipv6: [String]
        var isLoopback: Bool
        var isVirtual: Bool
        var ssid: String
        var gateway: String

        var interfaceType: String {
            if isLoopback { return "Loopback" }
            if !ssid.isEmpty { return "Wireless80211" }
            return "Ethernet"
        }

        func json() -> [String: Any] {
            [
                "Name": name,
                "Description": name,
                "Status": (ipv4.isEmpty && ipv6.isEmpty) ? "Down" : "Up",
                "InterfaceType": interfaceType,
                "MacAddress": NSNull(),
                "Ssid": ssid.isEmpty ? NSNull() : ssid,
                "LinkSpeedBps": NSNull(),
                "IPv4Addresses": ipv4,
                "IPv6Addresses": ipv6,
                "DefaultGateway": gateway.isEmpty ? NSNull() : gateway,
                "DnsServers": [String](),
                "DhcpEnabled": false,
                "DhcpServer": NSNull(),
                "IsLoopback": isLoopback,
                "IsVirtual": isVirtual
            ]
        }
    }

    private static func adapters(from snapshot: ClientSnapshot) -> [Adapter] {
        var order: [String] = []
        var buckets: [String: Adapter] = [:]
        for interface in snapshot.network?.interfaces ?? [] {
            let name = interface.name
            if buckets[name] == nil {
                order.append(name)
                buckets[name] = Adapter(
                    name: name,
                    ipv4: [],
                    ipv6: [],
                    isLoopback: name == "lo0",
                    isVirtual: isVirtualInterface(name),
                    ssid: "",
                    gateway: ""
                )
            }
            guard var adapter = buckets[name] else { continue }
            if interface.family == "ipv4" {
                if interface.address == "127.0.0.1" { adapter.isLoopback = true }
                if !adapter.ipv4.contains(interface.address) { adapter.ipv4.append(interface.address) }
            } else if interface.family == "ipv6" {
                if interface.address == "::1" { adapter.isLoopback = true }
                if !adapter.ipv6.contains(interface.address) { adapter.ipv6.append(interface.address) }
            }
            buckets[name] = adapter
        }
        let ssid = snapshot.sensitive?.wifiSsid ?? ""
        let gatewayName = snapshot.network?.gateway?.interfaceName
        var adapters = order.compactMap { buckets[$0] }
        if !ssid.isEmpty {
            let index = adapters.firstIndex { adapter in
                if let gatewayName { return adapter.name == gatewayName }
                return !adapter.isLoopback && !adapter.isVirtual && !adapter.ipv4.isEmpty
            }
            if let index {
                adapters[index].ssid = ssid
            }
        }
        let gatewayAddress = snapshot.network?.gateway?.address ?? ""
        if !gatewayAddress.isEmpty {
            let index = adapters.firstIndex { adapter in
                if let gatewayName { return adapter.name == gatewayName }
                return !adapter.isLoopback && !adapter.ipv4.isEmpty
            }
            if let index {
                adapters[index].gateway = gatewayAddress
            }
        }
        return adapters
    }

    private static func primaryIPv4(in adapters: [Adapter], boundInterface: String?) -> String? {
        if let bound = boundInterface, !bound.isEmpty {
            return adapters.first { $0.name == bound }?.ipv4.first
        }
        let preferred = adapters.first { !$0.isLoopback && !$0.isVirtual && !$0.ipv4.isEmpty }
            ?? adapters.first { !$0.isLoopback && !$0.ipv4.isEmpty }
        return preferred?.ipv4.first
    }

    private static func isVirtualInterface(_ name: String) -> Bool {
        let prefixes = ["utun", "awdl", "bridge", "llw", "gif", "stf", "ap", "ipsec", "pktap"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

enum DotNetDateTimeOffset {
    static func string(_ date: Date) -> String {
        var whole = date.timeIntervalSince1970.rounded(.down)
        var ticks = Int(((date.timeIntervalSince1970 - whole) * 10_000_000).rounded())
        if ticks >= 10_000_000 {
            ticks = 0
            whole += 1
        }
        if ticks < 0 {
            ticks = 0
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let base = formatter.string(from: Date(timeIntervalSince1970: whole))
        return String(format: "%@.%07d+00:00", locale: Locale(identifier: "en_US_POSIX"), base, ticks)
    }
}

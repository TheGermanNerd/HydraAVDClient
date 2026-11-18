import Darwin
import Foundation
import HydraAgentCore
import IOKit

/// The Hydra endpoint graphs plot `IReadOnlyList<PerformanceSample>` as a
/// line over the last hour. One sample does not draw a line, and an empty
/// `Disks` or `Networks` array leaves that graph with no series.
///
/// The Windows plugin samples every 5 seconds, keeps 60 minutes, and never
/// more than 720 points (`DiagnosticOptions`). Each `performance` response
/// is that whole list.
struct DiskCounter: Equatable {
    var name: String
    var readBytes: UInt64
    var writeBytes: UInt64
    var readOperations: UInt64
    var writeOperations: UInt64
    var busyNanoseconds: UInt64
}

struct NetworkCounter: Equatable {
    var name: String
    var ipv4: String
    var receiveBytes: UInt64
    var transmitBytes: UInt64
    var receivePackets: UInt64
    var transmitPackets: UInt64
    var linkSpeedBps: UInt64
}

enum PerformanceRates {
    static func disks(
        previous: [DiskCounter],
        current: [DiskCounter],
        elapsed: TimeInterval?
    ) -> [[String: Any]] {
        let prior = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return current.map { disk in
            let before = prior[disk.name]
            return [
                "DiskName": disk.name,
                "ReadIops": perSecond(disk.readOperations, before?.readOperations, elapsed),
                "WriteIops": perSecond(disk.writeOperations, before?.writeOperations, elapsed),
                "ReadBytesPerSecond": perSecond(disk.readBytes, before?.readBytes, elapsed),
                "WriteBytesPerSecond": perSecond(disk.writeBytes, before?.writeBytes, elapsed),
                "UtilizationPercentage": utilization(
                    current: disk.busyNanoseconds,
                    previous: before?.busyNanoseconds,
                    elapsed: elapsed
                )
            ]
        }
    }

    static func networks(
        previous: [NetworkCounter],
        current: [NetworkCounter],
        elapsed: TimeInterval?
    ) -> [[String: Any]] {
        let prior = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return current.map { interface in
            let before = prior[interface.name]
            let receive = perSecond(interface.receiveBytes, before?.receiveBytes, elapsed)
            let transmit = perSecond(interface.transmitBytes, before?.transmitBytes, elapsed)
            return [
                "InterfaceName": interface.name,
                "IPv4Address": interface.ipv4,
                "ReceiveBytesPerSecond": receive,
                "TransmitBytesPerSecond": transmit,
                "ReceivePacketsPerSecond": perSecond(interface.receivePackets, before?.receivePackets, elapsed),
                "TransmitPacketsPerSecond": perSecond(interface.transmitPackets, before?.transmitPackets, elapsed),
                "ReceiveUtilizationPercentage": linkUtilization(bytesPerSecond: receive, linkSpeedBps: interface.linkSpeedBps),
                "TransmitUtilizationPercentage": linkUtilization(bytesPerSecond: transmit, linkSpeedBps: interface.linkSpeedBps),
                "WifiLinkSpeedBps": linkSpeed(interface.linkSpeedBps)
            ]
        }
    }

    static func idleNetwork(name: String) -> [String: Any] {
        [
            "InterfaceName": name,
            "IPv4Address": "",
            "ReceiveBytesPerSecond": 0.0,
            "TransmitBytesPerSecond": 0.0,
            "ReceivePacketsPerSecond": 0.0,
            "TransmitPacketsPerSecond": 0.0,
            "ReceiveUtilizationPercentage": NSNull(),
            "TransmitUtilizationPercentage": NSNull(),
            "WifiLinkSpeedBps": NSNull()
        ]
    }

    private static func perSecond(_ current: UInt64, _ previous: UInt64?, _ elapsed: TimeInterval?) -> Double {
        guard let elapsed, elapsed > 0, let previous, current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }

    private static func utilization(current: UInt64, previous: UInt64?, elapsed: TimeInterval?) -> Double {
        guard let elapsed, elapsed > 0, let previous, current >= previous else { return 0 }
        let span = elapsed * 1_000_000_000
        guard span > 0 else { return 0 }
        return min(100, Double(current - previous) / span * 100)
    }

    private static func linkUtilization(bytesPerSecond: Double, linkSpeedBps: UInt64) -> Any {
        guard linkSpeedBps > 0 else { return NSNull() }
        return min(100, bytesPerSecond * 8 / Double(linkSpeedBps) * 100)
    }

    private static func linkSpeed(_ bps: UInt64) -> Any {
        guard bps > 0, bps <= UInt64(Int64.max) else { return NSNull() }
        return Int64(bps)
    }
}

struct PerformanceSeries {
    static let retention: TimeInterval = 60 * 60
    static let maximumCount = 720

    private var samples: [(date: Date, body: [String: Any])] = []

    var count: Int { samples.count }

    mutating func append(_ body: [String: Any], at date: Date) {
        samples.append((date, body))
        let cutoff = date.addingTimeInterval(-Self.retention)
        while let oldest = samples.first, samples.count > Self.maximumCount || oldest.date < cutoff {
            samples.removeFirst()
        }
    }

    func json() -> String {
        EndpointInventory.json(samples.map(\.body))
    }
}

/// Samples on the Windows interval and answers `performance` with the retained list.
public final class PerformanceMonitor {
    static let interval: TimeInterval = 5

    var counters: () -> (disks: [DiskCounter], networks: [NetworkCounter]) = {
        (PerformanceCounters.disks(), PerformanceCounters.networks())
    }
    var now: () -> Date = Date.init

    public init() {
        counters = { [weak self] in
            let name = self?.currentInterface() ?? ""
            return (PerformanceCounters.disks(), PerformanceCounters.networks(including: name))
        }
    }

    private let lock = NSLock()
    private var series = PerformanceSeries()
    private var previousDisks: [DiskCounter] = []
    private var previousNetworks: [NetworkCounter] = []
    private var previousAt: Date?
    private var latency: [String: Any] = EndpointInventory.emptyLatency()
    private var interfaceName = ""
    private var timer: DispatchSourceTimer?

    public func start() {
        lock.lock()
        if timer != nil {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        lock.unlock()
        source.resume()
        tick()
    }

    public func setNetworkInterface(_ name: String) {
        lock.lock()
        interfaceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
    }

    public func record(snapshot: ClientSnapshot) -> String {
        lock.lock()
        latency = EndpointInventory.latency(snapshot)
        lock.unlock()
        tick()
        lock.lock()
        defer { lock.unlock() }
        return series.json()
    }

    deinit {
        timer?.cancel()
    }

    private func currentInterface() -> String {
        lock.lock()
        defer { lock.unlock() }
        return interfaceName
    }

    private func tick() {
        let reading = counters()
        let memory = EndpointInventory.hostMemory()
        let cpu = CpuMeter.percent()
        let date = now()
        lock.lock()
        defer { lock.unlock() }
        let elapsed = previousAt.map { date.timeIntervalSince($0) }
        let networks = PerformanceRates.networks(
            previous: previousNetworks,
            current: reading.networks,
            elapsed: elapsed
        )
        let sample = EndpointInventory.performanceSample(
            at: date,
            cpuPercent: cpu,
            totalMemoryBytes: memory.total,
            usedMemoryBytes: memory.used,
            disks: PerformanceRates.disks(previous: previousDisks, current: reading.disks, elapsed: elapsed),
            networks: visibleNetworks(networks),
            latency: latency
        )
        series.append(sample, at: date)
        previousDisks = reading.disks
        previousNetworks = reading.networks
        previousAt = date
    }

    private func visibleNetworks(_ samples: [[String: Any]]) -> [[String: Any]] {
        guard !interfaceName.isEmpty else { return samples }
        let matched = samples.filter { $0["InterfaceName"] as? String == interfaceName }
        if !matched.isEmpty { return matched }
        return [PerformanceRates.idleNetwork(name: interfaceName)]
    }
}

enum PerformanceCounters {
    static func disks() -> [DiskCounter] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var results: [DiskCounter] = []
        var seen: [String: Int] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary else {
                continue
            }
            let rawName = wholeDiskName(of: service) ?? "disk"
            let count = seen[rawName, default: 0]
            seen[rawName] = count + 1
            let name = count == 0 ? rawName : "\(rawName)-\(count + 1)"
            let readBytes = integer(stats["Bytes (Read)"])
            let writeBytes = integer(stats["Bytes (Write)"])
            let readOperations = integer(stats["Operations (Read)"])
            let writeOperations = integer(stats["Operations (Write)"])
            if readBytes == 0, writeBytes == 0, readOperations == 0, writeOperations == 0 {
                continue
            }
            let busy = integer(stats["Total Time (Read)"]) &+ integer(stats["Total Time (Write)"])
            results.append(DiskCounter(
                name: name,
                readBytes: readBytes,
                writeBytes: writeBytes,
                readOperations: readOperations,
                writeOperations: writeOperations,
                busyNanoseconds: busy
            ))
        }
        return results
    }

    static func networks(including boundName: String = "") -> [NetworkCounter] {
        let addresses = ipv4Addresses()
        return interfaceStats(including: boundName).compactMap { stat in
            var stat = stat
            stat.ipv4 = addresses[stat.name] ?? ""
            let selected = stat.name == boundName
            let live = !stat.ipv4.isEmpty || stat.receiveBytes > 0 || stat.transmitBytes > 0
            if !selected && !live { return nil }
            return stat
        }
    }

    /// `getifaddrs` only fills the 32-bit `if_data` counters, which read as zero
    /// on the interfaces that actually carry traffic. `NET_RT_IFLIST2` is the
    /// 64-bit table.
    private static func interfaceStats(including boundName: String) -> [NetworkCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<if_msghdr2>.alignment
        )
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer, &size, nil, 0) == 0 else { return [] }

        var results: [NetworkCounter] = []
        var cursor = 0
        while cursor + MemoryLayout<UInt16>.size <= size {
            let message = buffer.advanced(by: cursor)
            let length = Int(message.assumingMemoryBound(to: UInt16.self).pointee)
            if length <= 0 { break }
            if cursor + length <= size, length >= MemoryLayout<if_msghdr2>.size {
                let header = message.assumingMemoryBound(to: if_msghdr2.self).pointee
                if header.ifm_type == RTM_IFINFO2 {
                    let flags = Int32(header.ifm_flags)
                    let name = interfaceName(at: message)
                    let loopback = (flags & IFF_LOOPBACK) != 0
                    let virtual = isVirtual(name) && name != boundName
                    let down = (flags & IFF_UP) == 0 && name != boundName
                    if !name.isEmpty, !loopback, !virtual, !down {
                        let data = header.ifm_data
                        results.append(NetworkCounter(
                            name: name,
                            ipv4: "",
                            receiveBytes: data.ifi_ibytes,
                            transmitBytes: data.ifi_obytes,
                            receivePackets: data.ifi_ipackets,
                            transmitPackets: data.ifi_opackets,
                            linkSpeedBps: data.ifi_baudrate
                        ))
                    }
                }
            }
            cursor += length
        }
        return results
    }

    private static func interfaceName(at message: UnsafeMutableRawPointer) -> String {
        let address = message.advanced(by: MemoryLayout<if_msghdr2>.stride)
        let link = address.assumingMemoryBound(to: sockaddr_dl.self).pointee
        let count = Int(link.sdl_nlen)
        guard count > 0 else { return "" }
        let data = address + (MemoryLayout.offset(of: \sockaddr_dl.sdl_data) ?? 8)
        let bytes = UnsafeRawBufferPointer(start: data, count: count)
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private static func ipv4Addresses() -> [String: String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var addresses: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            cursor = interface.pointee.ifa_next
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: interface.pointee.ifa_name)
            if addresses[name] == nil,
               let ip = numericHost(address, length: socklen_t(MemoryLayout<sockaddr_in>.size)) {
                addresses[name] = ip
            }
        }
        return addresses
    }

    /// IOMedia, which carries the BSD name, is a client of the storage driver.
    private static func wholeDiskName(of entry: io_registry_entry_t, depth: Int = 0) -> String? {
        if depth > 6 { return nil }
        if boolProperty(entry, "Whole") == true, let name = stringProperty(entry, "BSD Name") {
            return name
        }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else {
            return stringProperty(entry, "BSD Name")
        }
        defer { IOObjectRelease(children) }
        var fallback: String?
        while true {
            let child = IOIteratorNext(children)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            if let name = wholeDiskName(of: child, depth: depth + 1) {
                return name
            }
            if fallback == nil {
                fallback = stringProperty(child, "BSD Name")
            }
        }
        return fallback ?? stringProperty(entry, "BSD Name")
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func boolProperty(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func integer(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        let ip = String(cString: host)
        return ip.isEmpty ? nil : ip
    }

    private static func isVirtual(_ name: String) -> Bool {
        let prefixes = ["utun", "awdl", "bridge", "llw", "gif", "stf", "ap", "ipsec", "pktap", "anpi", "vmenet", "vmnet"]
        return prefixes.contains { name.hasPrefix($0) }
    }
}

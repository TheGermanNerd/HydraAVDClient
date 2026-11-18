import Foundation
import IOKit
import IOKit.ps

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func int64(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == MemoryLayout<UInt64>.size {
            var value: UInt64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            guard value <= UInt64(Int64.max) else { return nil }
            return Int64(value)
        }
        if size == MemoryLayout<Int32>.size {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        return nil
    }
}

enum DeviceCollector {
    static func collect(displays: [DisplayInfo], gpus: [String]) -> (DeviceSection, [String]) {
        var errors: [String] = []
        let version = operatingSystem()
        if version.version.isEmpty {
            errors.append("Operating system version was not available.")
        }
        let model = Sysctl.string("hw.model") ?? "unknown"
        let cpuBrand = Sysctl.string("machdep.cpu.brand_string") ?? model
        let cpuCount = Int(Sysctl.int64("hw.ncpu") ?? 0)
        let memory = Sysctl.int64("hw.memsize") ?? 0
        if cpuCount == 0 {
            errors.append("CPU count was not available.")
        }
        if memory == 0 {
            errors.append("Memory size was not available.")
        }

        let section = DeviceSection(
            productName: version.name,
            productVersion: version.version,
            buildVersion: version.build,
            hardwareModel: model,
            cpuBrand: cpuBrand,
            cpuCount: cpuCount,
            memoryBytes: memory,
            disks: disks(),
            gpus: gpus,
            displays: displays,
            battery: battery()
        )
        return (section, errors)
    }

    static func loadGPUNames() -> [String]? {
        let output = ProcessRunner.run(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPDisplaysDataType", "-json"],
            timeout: 20
        )
        guard !output.timedOut, let data = output.text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPDisplaysDataType"] as? [[String: Any]] else {
            return nil
        }
        let names = items.compactMap { item -> String? in
            if let model = item["sppci_model"] as? String, !model.isEmpty {
                return model
            }
            if let name = item["_name"] as? String, !name.isEmpty {
                return name
            }
            return nil
        }
        return names
    }

    private static func operatingSystem() -> (name: String, version: String, build: String) {
        let output = ProcessRunner.run(executable: "/usr/bin/sw_vers", arguments: [], timeout: 5)
        var name = ""
        var version = ""
        var build = ""
        for line in output.text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "ProductName": name = parts[1]
            case "ProductVersion": version = parts[1]
            case "BuildVersion": build = parts[1]
            default: break
            }
        }
        if version.isEmpty {
            let plist = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
            if let dict = NSDictionary(contentsOf: plist) {
                name = dict["ProductName"] as? String ?? name
                version = dict["ProductVersion"] as? String ?? version
                build = dict["ProductBuildVersion"] as? String ?? build
            }
        }
        if name.isEmpty { name = "macOS" }
        return (name, version, build)
    }

    private static func disks() -> [DiskInfo] {
        let keys: [URLResourceKey] = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsInternalKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        var disks: [DiskInfo] = []
        for url in urls {
            if let info = disk(at: url, keys: keys, requireInternal: true) {
                disks.append(info)
            }
        }
        if disks.isEmpty, let root = disk(at: URL(fileURLWithPath: "/"), keys: keys, requireInternal: false) {
            disks.append(root)
        }
        return disks.sorted { $0.mountPoint < $1.mountPoint }
    }

    private static func disk(at url: URL, keys: [URLResourceKey], requireInternal: Bool) -> DiskInfo? {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if requireInternal && values?.volumeIsInternal != true { return nil }
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        guard total > 0 else { return nil }
        return DiskInfo(
            mountPoint: url.path,
            totalBytes: total,
            availableBytes: Int64(values?.volumeAvailableCapacity ?? 0),
            fileSystem: values?.volumeLocalizedFormatDescription
        )
    }

    private static func battery() -> BatteryInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return BatteryInfo(present: false, chargePercentage: nil, isCharging: nil)
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryInfo(present: false, chargePercentage: nil, isCharging: nil)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let current = integer(description[kIOPSCurrentCapacityKey as String])
            let maximum = integer(description[kIOPSMaxCapacityKey as String])
            let charging = description[kIOPSIsChargingKey as String] as? Bool
            let percent: Int?
            if let current, let maximum, maximum > 0 {
                let ratio = (Double(current) / Double(maximum) * 100).rounded()
                percent = min(100, Swift.max(0, Int(ratio)))
            } else {
                percent = current
            }
            return BatteryInfo(present: true, chargePercentage: percent, isCharging: charging)
        }
        return BatteryInfo(present: false, chargePercentage: nil, isCharging: nil)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

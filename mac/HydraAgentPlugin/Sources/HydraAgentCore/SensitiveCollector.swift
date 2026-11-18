import CoreWLAN
import Foundation
import IOKit

enum SensitiveCollector {
    static func current(location: LocationFix?) -> SensitiveSection {
        let user = NSUserName()
        let computer = Host.current().localizedName
        return SensitiveSection(
            userName: user.isEmpty ? nil : user,
            computerName: computer,
            serialNumber: serialNumber(),
            wifiSsid: wifiSSID(),
            location: location
        )
    }

    private static func serialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformSerialNumber" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        let value = property.takeRetainedValue() as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed?.isEmpty == true { return nil }
        return trimmed
    }

    private static func wifiSSID() -> String? {
        guard let name = CWWiFiClient.shared().interface()?.ssid() else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

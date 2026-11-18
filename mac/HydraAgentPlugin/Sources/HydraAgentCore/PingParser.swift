import Foundation

public enum PingParser {
    public struct Parsed: Equatable {
        public var reachable: Bool
        public var latencyMs: Double?

        public init(reachable: Bool, latencyMs: Double?) {
            self.reachable = reachable
            self.latencyMs = latencyMs
        }
    }

    /// Hostnames and IP addresses only. Rejects spaces, shell metacharacters, and empty strings.
    public static func isValidTarget(_ raw: String) -> Bool {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...253).contains(target.count) else { return false }
        guard !target.contains("..") else { return false }
        guard target.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil else {
            return false
        }
        return true
    }

    public static func parse(_ output: String) -> Parsed {
        let lowered = output.lowercased()
        if lowered.contains("unknown host") || lowered.contains("name or service not known") {
            return Parsed(reachable: false, latencyMs: nil)
        }

        let loss = firstCapture(#"([0-9]+(?:\.[0-9]+)?)%\s*packet loss"#, in: output).flatMap(Double.init)
        let received = firstCapture(#"([0-9]+)\s+packets received"#, in: output).flatMap(Int.init)
        let latency = firstCapture(#"time[=<]\s*([0-9]+(?:\.[0-9]+)?)\s*ms"#, in: output).flatMap(Double.init)

        let lostAll = (loss ?? 0) >= 100 || received == 0
        if lostAll || latency == nil {
            return Parsed(reachable: false, latencyMs: nil)
        }
        return Parsed(reachable: true, latencyMs: latency)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }
}

public enum SecurityStatusParser {
    public static func fileVaultEnabled(from output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("filevault is on") { return true }
        if text.contains("filevault is off") { return false }
        return nil
    }

    /// "disabled" contains the letters of "enabled", so the state value is checked first.
    public static func firewallEnabled(from output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("state = 1") || text.contains("state=1") { return true }
        if text.contains("state = 0") || text.contains("state=0") { return false }
        if text.contains("disabled") { return false }
        if text.contains("enabled") { return true }
        return nil
    }
}

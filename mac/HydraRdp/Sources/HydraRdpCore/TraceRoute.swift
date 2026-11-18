import Foundation

/// One hop from the Windows `TraceRouteHop` model.
public struct TraceHop: Equatable, Sendable {
    public var hopNumber: Int
    public var address: String?
    public var hostName: String?
    public var latenciesMs: [Double]
    public var timedOut: Bool
    public var reachedTarget: Bool

    public init(
        hopNumber: Int,
        address: String?,
        hostName: String?,
        latenciesMs: [Double],
        timedOut: Bool,
        reachedTarget: Bool
    ) {
        self.hopNumber = hopNumber
        self.address = address
        self.hostName = hostName
        self.latenciesMs = latenciesMs
        self.timedOut = timedOut
        self.reachedTarget = reachedTarget
    }
}

/// The Windows `TraceRouteResult`: the target, each hop, and whether a hop was the target.
public struct TraceRouteResult: Equatable, Sendable {
    public var target: String
    public var hops: [TraceHop]
    public var reachedTarget: Bool

    public init(target: String, hops: [TraceHop], reachedTarget: Bool) {
        self.target = target
        self.hops = hops
        self.reachedTarget = reachedTarget
    }
}

/// Limits copied from `NetworkDiagnosticsOptions` and `TraceRouteCollector`.
enum TraceRouteLimits {
    static let maxHops = 30
    static let probesPerHop = 3
    static let timeoutSeconds = 1
    static let budget: TimeInterval = 15
    static let maxSilentHops = 3
}

/// Reads `traceroute` text into the hop list the MSI returns.
enum TraceRouteParser {
    static func parse(_ output: String, target: String) -> TraceRouteResult {
        let requested = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = resolvedAddress(in: output)
        var hops: [TraceHop] = []
        var draft: Draft?
        var silent = 0
        var stopped = false

        func commit() {
            guard let current = draft else { return }
            draft = nil
            let hop = current.make(target: requested, resolved: resolved)
            hops.append(hop)
            if hop.reachedTarget {
                stopped = true
                return
            }
            if hop.timedOut {
                silent += 1
                if silent >= TraceRouteLimits.maxSilentHops {
                    stopped = true
                }
            } else {
                silent = 0
            }
        }

        for line in output.split(whereSeparator: \.isNewline) {
            if stopped { break }
            let text = String(line)
            let previous = draft?.number ?? hops.last?.hopNumber ?? 0
            if let start = hopStart(text), start.number == previous + 1 {
                commit()
                if stopped { break }
                draft = Draft(number: start.number)
                draft?.consume(start.remainder)
            } else if draft != nil {
                draft?.consume(text)
            }
        }
        if !stopped {
            commit()
        }
        return TraceRouteResult(
            target: requested,
            hops: hops,
            reachedTarget: hops.contains { $0.reachedTarget }
        )
    }

    private static func resolvedAddress(in output: String) -> String? {
        let prefix = "traceroute to "
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(prefix),
                  let open = text.lastIndex(of: "("),
                  let close = text.lastIndex(of: ")"),
                  open < close else { continue }
            let address = text[text.index(after: open)..<close]
            if !address.isEmpty { return String(address) }
        }
        return nil
    }

    /// A hop line starts with a hop number. Later lines that only repeat probes
    /// stay on the hop already opened.
    private static func hopStart(_ line: String) -> (number: Int, remainder: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        var digits = ""
        var rest = trimmed[...]
        while let character = rest.first, character.isNumber {
            digits.append(character)
            rest = rest.dropFirst()
        }
        guard let number = Int(digits), !digits.isEmpty else { return nil }
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let remainder = rest.drop(while: { $0 == " " || $0 == "\t" })
        return (number, String(remainder))
    }

    private struct Draft {
        var number: Int
        var address: String?
        var hostName: String?
        var latencies: [Double] = []

        mutating func consume(_ text: String) {
            let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                if token == "*" {
                    latencies.append(0)
                    index += 1
                    continue
                }
                if token.hasPrefix("!") {
                    index += 1
                    continue
                }
                if token.hasPrefix("("), token.hasSuffix(")"), token.count > 2 {
                    let inner = String(token.dropFirst().dropLast())
                    if address == nil { address = inner }
                    index += 1
                    continue
                }
                if let latency = latencyValue(token, upcoming: index + 1 < tokens.count ? tokens[index + 1] : nil) {
                    latencies.append(latency.value)
                    index += latency.consumed
                    continue
                }
                if isNumericAddress(token) {
                    if address == nil { address = token }
                    index += 1
                    continue
                }
                if hostName == nil {
                    hostName = token
                }
                index += 1
            }
        }

        func make(target: String, resolved: String?) -> TraceHop {
            var samples = latencies
            if samples.count < TraceRouteLimits.probesPerHop {
                samples.append(contentsOf: repeatElement(0, count: TraceRouteLimits.probesPerHop - samples.count))
            }
            let timedOut = address == nil
            let name = timedOut ? nil : symbolicName(hostName, address: address)
            let reached = !timedOut && addressMatchesTarget(address, target: target, resolved: resolved)
            return TraceHop(
                hopNumber: number,
                address: address,
                hostName: name,
                latenciesMs: samples,
                timedOut: timedOut,
                reachedTarget: reached
            )
        }
    }

    private static func latencyValue(_ token: String, upcoming: String?) -> (value: Double, consumed: Int)? {
        let lower = token.lowercased()
        if lower.hasSuffix("ms"), lower.count > 2, let value = Double(lower.dropLast(2)) {
            return (value, 1)
        }
        if let value = Double(token), let upcoming, upcoming.lowercased().hasPrefix("ms") {
            return (value, 2)
        }
        return nil
    }

    private static func symbolicName(_ name: String?, address: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        if let address, name.caseInsensitiveCompare(address) == .orderedSame { return nil }
        if isNumericAddress(name) { return nil }
        return name
    }

    private static func addressMatchesTarget(_ address: String?, target: String, resolved: String?) -> Bool {
        guard let address else { return false }
        if address.caseInsensitiveCompare(target) == .orderedSame { return true }
        if let resolved, address.caseInsensitiveCompare(resolved) == .orderedSame { return true }
        return false
    }

    static func isNumericAddress(_ value: String) -> Bool {
        if value.contains(":") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count >= 3 && value.allSatisfy { $0.isHexDigit || $0 == ":" }
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = Int(part), part.count <= 3 else { return false }
            return (0...255).contains(octet) && (part.count == 1 || !part.hasPrefix("0"))
        }
    }
}

public typealias TraceRouteProbe = @Sendable (String, String?) -> TraceRouteResult?

/// Runs the same ICMP traceroute the MSI builds with rising TTLs.
enum TraceRouteRunner {
    static func probe(target: String, interfaceName: String?) -> TraceRouteResult? {
        guard let icmp = arguments(target: target, interfaceName: interfaceName, icmp: true) else {
            return nil
        }
        let first = run(icmp)
        let chosen: String
        if shouldRetryWithoutIcmp(output: first.text, hopCount: TraceRouteParser.parse(first.text, target: target).hops.count) {
            guard let plain = arguments(target: target, interfaceName: interfaceName, icmp: false) else {
                return nil
            }
            chosen = run(plain).text
        } else {
            chosen = first.text
        }
        let parsed = TraceRouteParser.parse(chosen, target: target)
        return parsed.hops.isEmpty ? nil : parsed
    }

    static func arguments(target: String, interfaceName: String?, icmp: Bool) -> [String]? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeTarget(trimmed) else { return nil }
        var arguments = [
            "-q", String(TraceRouteLimits.probesPerHop),
            "-m", String(TraceRouteLimits.maxHops),
            "-w", String(TraceRouteLimits.timeoutSeconds)
        ]
        let interface = interfaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isSafeInterface(interface) {
            arguments.append(contentsOf: ["-i", interface])
        }
        if icmp {
            arguments.append("-I")
        }
        arguments.append(trimmed)
        return arguments
    }

    /// ICMP traceroute needs a raw socket. When the system refuses it, the
    /// same command without `-I` still lists each hop.
    static func shouldRetryWithoutIcmp(output: String, hopCount: Int) -> Bool {
        guard hopCount == 0 else { return false }
        let lower = output.lowercased()
        return lower.contains("not permitted") || lower.contains("permission denied")
    }

    private static func isSafeTarget(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253, !value.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-:")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeInterface(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter, value.count <= 16 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func run(_ arguments: [String]) -> (text: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return ("", 1)
        }
        let group = DispatchGroup()
        let collected = Collected()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collected.output = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collected.errors = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(TraceRouteLimits.budget)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        group.wait()
        let text = String(data: collected.output + collected.errors, encoding: .utf8) ?? ""
        return (text, process.terminationStatus)
    }

    /// Mutable box so the pipe readers can return bytes without capturing `inout`.
    private final class Collected: @unchecked Sendable {
        var output = Data()
        var errors = Data()
    }
}

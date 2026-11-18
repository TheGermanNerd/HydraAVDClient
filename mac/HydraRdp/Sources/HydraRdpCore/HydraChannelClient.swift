import CryptoKit
import Darwin
import Foundation
import HydraAgentCore
import HydraChannelProtocol
import Security

public protocol ChannelLog: AnyObject {
    func info(_ message: String)
    func error(_ message: String)
}

public struct ChannelLogLine: Equatable {
    public var level: String
    public var message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }
}

public final class MemoryChannelLog: ChannelLog {
    public private(set) var lines: [ChannelLogLine] = []

    public init() {}

    public func info(_ message: String) {
        lines.append(ChannelLogLine(level: "info", message: message))
    }

    public func error(_ message: String) {
        lines.append(ChannelLogLine(level: "error", message: message))
    }

    public var text: String {
        lines.map { "\($0.level) \($0.message)" }.joined(separator: "\n")
    }
}

public protocol InventoryProviding: AnyObject {
    func loadSnapshot() async -> ClientSnapshot
    func cpuPercent() -> Double
    func performanceJSON() async -> String
}

extension InventoryProviding {
    public func performanceJSON() async -> String {
        EndpointInventory.performance(await loadSnapshot(), cpuPercent: cpuPercent())
    }
}

public enum ChannelEvent: Equatable {
    case write(Data)
    case close
}

public actor HydraChannelClient {
    private enum Phase {
        case awaitingChallengeRequest
        case awaitingResponse
        case authenticated
        case closed
    }

    private let clientKey: String
    private let inventory: InventoryProviding
    private let log: ChannelLog
    private var phase = Phase.awaitingChallengeRequest
    private var nonce = ""
    private let version: Int64
    private let trace: TraceRouteProbe

    public init(
        clientKey: String,
        inventory: InventoryProviding,
        log: ChannelLog,
        version: Int64 = ClientVersion.packed(major: 1, minor: 0, build: 0, revision: 0),
        trace: TraceRouteProbe? = nil
    ) {
        self.clientKey = clientKey
        self.inventory = inventory
        self.log = log
        self.version = version
        self.trace = trace ?? { target, interfaceName in
            TraceRouteRunner.probe(target: target, interfaceName: interfaceName)
        }
    }

    public func receive(_ data: Data) async -> [ChannelEvent] {
        guard phase != .closed else { return [] }
        if data.isEmpty || data.count > HydraChannelProtocol.maximumAcceptedBytes {
            record("info", "dropped channel callback of \(data.count) bytes")
            return []
        }
        if data.count < HydraChannelProtocol.totalHeaderSize {
            record("error", "rejected short channel frame")
            return closeChannel()
        }
        guard let decoded = HydraChannelProtocol.Frame.decode(data) else {
            record("error", "rejected channel frame")
            return closeChannel()
        }
        return await handle(decoded.frame)
    }

    private func handle(_ frame: HydraChannelProtocol.Frame) async -> [ChannelEvent] {
        let type = HydraChannelProtocol.MessageType(rawValue: frame.messageType)
        switch phase {
        case .awaitingChallengeRequest:
            guard type == .authChallengeRequest else {
                record("error", "closed channel before authentication")
                return closeChannel()
            }
            nonce = ChannelAuthenticator.nonce()
            phase = .awaitingResponse
            record("info", "sent auth challenge")
            let reply = HydraChannelProtocol.Frame(
                messageType: .authChallenge,
                sequence: HydraChannelHandshake.authChallengeSequence,
                payload: nonce
            )
            return [.write(reply.encoded())]
        case .awaitingResponse:
            guard type == .authResponse else {
                record("error", "closed channel waiting for auth response")
                return closeChannel()
            }
            guard ChannelAuthenticator.verify(secret: clientKey, nonce: nonce, presented: frame.payload) else {
                record("error", "auth response did not match")
                return closeChannel()
            }
            phase = .authenticated
            nonce = ""
            record("info", "channel authenticated")
            return []
        case .authenticated:
            guard type == .jsonRequest else {
                record("info", "ignored frame type \(frame.messageType)")
                return []
            }
            let payload = await answer(frame)
            let reply = HydraChannelProtocol.Frame(
                messageType: .jsonResponse,
                sequence: frame.sequence,
                payload: payload
            )
            return [.write(reply.encoded())]
        case .closed:
            return []
        }
    }

    /// Traces the internet ping target only. Gateway latency stays a single ping,
    /// and a skipped ping does not start a route.
    private func traceInternet(_ snapshot: ClientSnapshot) async -> TraceRouteResult? {
        guard let sample = snapshot.network?.internetPing, !sample.skipped else { return nil }
        let target = sample.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let interfaceName = snapshot.network?.boundInterface
        let probe = trace
        return await Task.detached(priority: .utility) {
            probe(target, interfaceName)
        }.value
    }

    private func answer(_ frame: HydraChannelProtocol.Frame) async -> String {
        let request = RequestJSON.parse(frame.payload)
        record("info", "command \(request.command.isEmpty ? "(empty)" : request.command)")
        switch request.command {
        case HydraChannelProtocol.Command.initialize:
            return initJSON(await inventory.loadSnapshot())
        case HydraChannelProtocol.Command.fullInventory:
            return EndpointInventory.systemInventory(await inventory.loadSnapshot(), cpuPercent: inventory.cpuPercent())
        case HydraChannelProtocol.Command.location:
            return EndpointInventory.location(await inventory.loadSnapshot())
        case HydraChannelProtocol.Command.network:
            let snapshot = await inventory.loadSnapshot()
            return EndpointInventory.network(
                snapshot,
                parameter: request.parameter,
                trace: await traceInternet(snapshot)
            )
        case HydraChannelProtocol.Command.performance:
            return await inventory.performanceJSON()
        case HydraChannelProtocol.Command.getTime:
            let status = HydraChannelProtocol.SimpleStatus.clientTimePrefix + DotNetTime.local(Date())
            return envelope(sequence: frame.sequence, status: status, receivedLength: request.characterLength)
        case HydraChannelProtocol.Command.ping:
            return envelope(
                sequence: frame.sequence,
                status: HydraChannelProtocol.SimpleStatus.pong,
                receivedLength: request.characterLength
            )
        default:
            let percent = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), inventory.cpuPercent())
            let status = HydraChannelProtocol.SimpleStatus.cpuPrefix + percent + HydraChannelProtocol.SimpleStatus.cpuSuffix
            return envelope(sequence: frame.sequence, status: status, receivedLength: request.characterLength)
        }
    }

    private func initJSON(_ snapshot: ClientSnapshot) -> String {
        let ip = snapshot.network?.interfaces.first { $0.family == "ipv4" }?.address ?? "0.0.0.0"
        let name = snapshot.sensitive?.computerName ?? "Mac"
        let body: [String: Any] = [
            HydraChannelProtocol.InitField.ipAddress: ip,
            HydraChannelProtocol.InitField.clientName: name,
            HydraChannelProtocol.InitField.timeStampUtc: DotNetTime.utc(Date()),
            HydraChannelProtocol.InitField.version: version
        ]
        return json(body)
    }

    private func envelope(sequence: UInt32, status: String, receivedLength: Int) -> String {
        let timestamp = DotNetTime.utc(Date())
        return #"{"type":"response","request_seq":\#(sequence),"ts":"\#(timestamp)","status":"\#(status)","received_len":\#(receivedLength)}"#
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func closeChannel() -> [ChannelEvent] {
        phase = .closed
        nonce = ""
        return [.close]
    }

    private func record(_ level: String, _ message: String) {
        let clean = redact(message)
        if level == "error" {
            log.error(clean)
        } else {
            log.info(clean)
        }
    }

    private func redact(_ message: String) -> String {
        guard clientKey.count >= 4 else { return message }
        return message.replacingOccurrences(of: clientKey, with: "[redacted]")
    }
}

public enum ClientVersion {
    public static func packed(major: Int, minor: Int, build: Int, revision: Int) -> Int64 {
        func clamp(_ value: Int) -> Int64 { Int64(min(9999, max(0, value))) }
        return clamp(major) * 1_000_000_000_000
            + clamp(minor) * 100_000_000
            + clamp(build) * 10_000
            + clamp(revision)
    }
}

enum ChannelAuthenticator {
    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: HydraChannelProtocol.nonceByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes).base64EncodedString()
    }

    static func hmacBase64(secret: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)
        return Data(code).base64EncodedString()
    }

    static func verify(secret: String, nonce: String, presented: String) -> Bool {
        let expected = Array(hmacBase64(secret: secret, nonce: nonce).utf8)
        let actual = Array(presented.utf8)
        guard expected.count == actual.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices {
            difference |= expected[index] ^ actual[index]
        }
        return difference == 0
    }
}

private struct RequestJSON {
    var command: String
    var parameter: String
    var characterLength: Int

    static func parse(_ payload: String) -> RequestJSON {
        let length = payload.utf16.count
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RequestJSON(command: "", parameter: "", characterLength: length)
        }
        let command = (object[HydraChannelProtocol.RequestField.command] as? String)?
            .lowercased() ?? ""
        let parameter = object[HydraChannelProtocol.RequestField.parameter] as? String ?? ""
        return RequestJSON(command: command, parameter: parameter, characterLength: length)
    }
}

public enum DotNetTime {
    public static func utc(_ date: Date) -> String {
        format(date, timeZone: TimeZone(secondsFromGMT: 0)!, utc: true)
    }

    public static func local(_ date: Date) -> String {
        format(date, timeZone: .current, utc: false)
    }

    private static func format(_ date: Date, timeZone: TimeZone, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = utc ? "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS'Z'" : "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSxxxxx"
        return formatter.string(from: date)
    }
}

public enum CpuMeter {
    private static let lock = NSLock()
    private static var previous: host_cpu_load_info?

    public static func percent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard let previous else {
            self.previous = info
            return 0
        }
        let user = diff(info.cpu_ticks.0, previous.cpu_ticks.0)
        let system = diff(info.cpu_ticks.1, previous.cpu_ticks.1)
        let idle = diff(info.cpu_ticks.2, previous.cpu_ticks.2)
        let nice = diff(info.cpu_ticks.3, previous.cpu_ticks.3)
        self.previous = info
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return (user + system + nice) / total * 100
    }

    private static func diff(_ current: UInt32, _ previous: UInt32) -> Double {
        Double(current &- previous)
    }
}

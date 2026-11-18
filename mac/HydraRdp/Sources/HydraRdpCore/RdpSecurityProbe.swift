import Darwin
import Foundation

/// Asks a saved PC which security it will accept before FreeRDP opens the session.
/// A host that requires Network Level Authentication resets the connection when no
/// user name and password are sent, and FreeRDP reports that reset as a transport failure.
public enum RdpSecurityProbe {
    public static let hybridRequiredByServer: UInt32 = 5
    public static let protocolHybrid: UInt32 = 2

    public enum Negotiation: Equatable {
        case selected(UInt32)
        case failure(UInt32)
    }

    public static func parse(_ data: Data) -> Negotiation? {
        guard data.count >= 19 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x03 else { return nil }
        let code = UInt32(bytes[15])
            | (UInt32(bytes[16]) << 8)
            | (UInt32(bytes[17]) << 16)
            | (UInt32(bytes[18]) << 24)
        switch bytes[11] {
        case 0x02:
            return .selected(code)
        case 0x03:
            return .failure(code)
        default:
            return nil
        }
    }

    /// `true` when a TLS-only negotiation response says the server demands NLA.
    public static func requiresNetworkLevelAuthentication(responseToTlsOnly data: Data) -> Bool {
        switch parse(data) {
        case .failure(hybridRequiredByServer), .selected(protocolHybrid):
            return true
        default:
            return false
        }
    }

    /// `true` when the host demands NLA, `false` when it accepts a connection without it,
    /// and `nil` when the host could not be asked.
    public static func requiresNetworkLevelAuthentication(host: String, timeout: TimeInterval = 4) async -> Bool? {
        guard let endpoint = endpoint(from: host) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            probe(host: endpoint.name, port: endpoint.port, timeout: timeout)
        }.value
    }

    static func endpoint(from host: String) -> (name: String, port: UInt16)? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let end = trimmed.firstIndex(of: "]") else { return nil }
            let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            guard !name.isEmpty else { return nil }
            let rest = trimmed[trimmed.index(after: end)...]
            if rest.isEmpty { return (name, 3389) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 else { return nil }
            return (name, port)
        }
        guard let colon = trimmed.lastIndex(of: ":"), colon != trimmed.startIndex else {
            return (trimmed, 3389)
        }
        let name = String(trimmed[..<colon])
        let portText = trimmed[trimmed.index(after: colon)...]
        guard !name.isEmpty, !name.contains(":"), let port = UInt16(portText), port > 0 else {
            return (trimmed, 3389)
        }
        return (name, port)
    }

    private static func probe(host: String, port: UInt16, timeout: TimeInterval) -> Bool? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }

        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let current = cursor {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                defer { close(fd) }
                if connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen, timeout: timeout) {
                    var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                    let request = tlsOnlyRequest
                    let sent = request.withUnsafeBytes { raw in
                        Darwin.send(fd, raw.baseAddress, raw.count, 0)
                    }
                    guard sent == request.count else { return nil }
                    var buffer = [UInt8](repeating: 0, count: 64)
                    let got = buffer.withUnsafeMutableBytes { raw in
                        recv(fd, raw.baseAddress, raw.count, 0)
                    }
                    guard got >= 19 else { return nil }
                    return requiresNetworkLevelAuthentication(responseToTlsOnly: Data(buffer.prefix(got)))
                }
            }
            cursor = current.pointee.ai_next
        }
        return nil
    }

    private static let tlsOnlyRequest: [UInt8] = [
        0x03, 0x00, 0x00, 0x13,
        0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00
    ]

    private static func connect(
        _ fd: Int32,
        _ address: UnsafePointer<sockaddr>?,
        _ length: socklen_t,
        timeout: TimeInterval
    ) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }
        let started = Darwin.connect(fd, address, length)
        if started == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return true
        }
        guard errno == EINPROGRESS else { return false }
        var pollInfo = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waited = poll(&pollInfo, 1, Int32(timeout * 1000))
        guard waited > 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return false }
        _ = fcntl(fd, F_SETFL, flags)
        return true
    }
}

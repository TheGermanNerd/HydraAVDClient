import Foundation

/// Wire protocol of the ITProCloud Hydra dynamic virtual channel, recovered from
/// `HydraAgentDvcPlugin.dll` (`RdpDvc.Client`) and `HydraAgentDvcShared.dll`
/// (`RdpDvc.Shared`) inside `HydraAgentClientPluginSetup.msi`.
///
/// The session-host executable that calls `WTSVirtualChannelRead` /
/// `WTSVirtualChannelWrite` is not in that MSI. Both sides share
/// `RdpDvc.Shared.JsonMessage` for the bytes on the channel. The client
/// behavior below is what `DvcPlugin.ChannelCallback` actually does.
///
/// The COM add-in key
/// `Software\Microsoft\Terminal Server Client\Default\AddIns\HydraAgentPlugIn`
/// is not the channel name. Its `Name` value is the plugin CLSID
/// (`{91f7c25f-a12f-4a8e-86ab-79e1a5492e31}`, `Guid.ToString("B")` in
/// `Program.Register`). `DvcPlugin.Initialize` calls `CreateListener` with the
/// ASCII bytes of `HYDAGX01`, including the terminating NUL
/// (`DvcPlugin.cctor`, constant `ChannelName`).
public enum HydraChannelProtocol {
    /// Dynamic virtual channel name. Eight ASCII characters, no NUL on the
    /// FreeRDP / MS-RDPEDYC name string. The listener constant is stored as
    /// the user string `HYDAGX01\0`.
    public static let channelName = "HYDAGX01"

    /// `JsonMessage.Magic`. `IsJsonFrame` accepts a buffer only when its
    /// length is greater than 4 and byte 4 equals this value.
    public static let magic: UInt8 = 0xFF

    /// `JsonMessage.InnerHeaderSize`. Magic (1) + message type (4) + sequence (4).
    public static let innerHeaderSize = 9

    /// `JsonMessage.TotalHeaderSize`. The 4-byte length prefix plus `innerHeaderSize`.
    /// `TryParse` rejects a buffer shorter than this.
    public static let totalHeaderSize = 13

    /// `ChannelCallback.OnDataReceived` drops a callback whose size is 0 or
    /// greater than this (16 MiB), or greater than the buffer length.
    public static let maximumAcceptedBytes = 16_777_216

    /// `ChannelChallengeAuth.NonceBytes`.
    public static let nonceByteCount = 32

    /// Message type at byte offset 5. `RdpDvc.Shared.MessageType`, a `UInt32`
    /// (`ELEMENT_TYPE_U4` constants). `JsonMessage.ReadU32` is
    /// `BitConverter.ToUInt32` and `WriteU32` is `BitConverter.GetBytes`.
    /// On Windows that is little-endian. Write these fields little-endian.
    public enum MessageType: UInt32 {
        /// Session host to client, and only after authentication.
        case jsonRequest = 1
        /// Client to session host. Every answered request uses this type.
        case jsonResponse = 2
        /// Session host to client. First frame. The payload is ignored.
        case authChallengeRequest = 3
        /// Client to session host. Payload is the nonce, sequence is 0.
        case authChallenge = 4
        /// Session host to client. Payload is the Base64 HMAC.
        case authResponse = 5
    }

    /// `ChannelCallback.AuthState`.
    public enum AuthState: UInt32 {
        case awaitingChallengeRequest = 0
        case awaitingResponse = 1
        case authenticated = 2
    }

    /// JSON property names read by `ChannelCallback.TryGetStringProperty`.
    /// `System.Text.Json` `TryGetProperty` is case-sensitive. The value must
    /// be a JSON string (`JsonValueKind.String` == 3). A missing `cmd`, or a
    /// non-string `cmd`, is treated as `""`.
    public enum RequestField {
        public static let command = "cmd"
        public static let parameter = "param"
    }

    /// `cmd` is lowercased with `ToLowerInvariant` before it is compared.
    ///
    /// `init`, `fullinventory`, `location`, `network`, and `performance`
    /// answer with message type `jsonResponse`, echoing the request sequence.
    /// The payload is the raw JSON text, not the envelope below.
    ///
    /// `gettime`, `ping`, and every other command use `BuildResponse`, which
    /// concatenates this envelope. `status` is inserted without JSON escaping.
    /// `request_seq` is the frame sequence. `received_len` is the character
    /// length of the whole request JSON text. `ts` is `DateTime.UtcNow`
    /// formatted with the `"O"` round-trip pattern.
    ///
    /// ```
    /// {"type":"response","request_seq":<seq>,"ts":"<utc O>","status":"<text>","received_len":<n>}
    /// ```
    public enum Command {
        public static let initialize = "init"
        public static let fullInventory = "fullinventory"
        public static let location = "location"
        public static let network = "network"
        public static let performance = "performance"
        public static let getTime = "gettime"
        public static let ping = "ping"
    }

    public enum ResponseEnvelopeField {
        public static let type = "type"
        public static let typeValue = "response"
        public static let requestSequence = "request_seq"
        public static let timestamp = "ts"
        public static let status = "status"
        public static let receivedLength = "received_len"
    }

    /// `BuildResponse` status text.
    public enum SimpleStatus {
        /// Prefix. The Windows client appends `DateTime.Now.ToString("O")`
        /// (local time, not UTC).
        public static let clientTimePrefix = "Client time is "
        public static let pong = "Pong"
        /// Prefix. The Windows client appends CPU percent with format `F1`,
        /// then `" %"`.
        public static let cpuPrefix = "Client CPU Usage is "
        public static let cpuSuffix = " %"
    }

    /// `init` payload from `ChannelCallback.BuildInitResponse`.
    /// `JsonSerializer.Serialize<ClientInfo>(value, options: null)`. There is
    /// no `JsonPropertyName` attribute and no naming policy, so the names are
    /// the CLR property names.
    ///
    /// `RdpDvc.Shared.SessionManager.MaskInitInfo` looks up the different
    /// names `ipAddress` and `clientName`, and only to redact the log line.
    /// It still stores the original JSON. These assemblies do not reject an
    /// init object that lacks either spelling.
    public enum InitField {
        public static let ipAddress = "IpAddress"
        public static let clientName = "ClientName"
        /// `DateTime.UtcNow.ToString("O")`, then stored as a string.
        public static let timeStampUtc = "TimeStampUtc"
        /// `Int64`. File version packed by `ClientInfo.EncodeVersion`:
        /// `major * 1_000_000_000_000 + minor * 100_000_000 + build * 10_000 + revision`,
        /// each part clamped to 0...9999. The Windows plugin uses
        /// `FileVersionInfo` of its own executable. A Mac build has no such
        /// file version; the integer is not checked by these assemblies.
        public static let version = "Version"
    }

    /// Where the Windows plugin keeps the channel secret. This value is not
    /// sent on the channel. `ChannelSecretStore.Set` stores UTF-8 bytes of
    /// the secret passed through `ProtectedData.Protect` with null entropy
    /// and `DataProtectionScope.LocalMachine` (1), as `RegistryValueKind.Binary`
    /// (3). `Get` reverses that. A Mac client cannot decrypt that blob. It
    /// needs the same plaintext string the administrator set.
    public enum ClientKeyStorage {
        public static let registryPath = "Software\\ITProCloud\\HydraAgentDvcPlugin"
        public static let valueName = "ChannelSecret"
    }

    /// One frame, matching `JsonMessage.Serialize` and `JsonMessage.TryParse`.
    ///
    /// ```
    /// offset 0  UInt32 LE  innerLength   // not including these 4 bytes
    /// offset 4  UInt8      magic         // 0xFF
    /// offset 5  UInt32 LE  messageType
    /// offset 9  UInt32 LE  sequence
    /// offset 13 UTF-8      payload       // innerLength - 9 bytes
    /// ```
    ///
    /// `innerLength` is `innerHeaderSize + payloadUtf8.count`. The whole frame
    /// is `4 + innerLength` bytes. `TryParse` fails when `innerLength` is
    /// greater than `buffer.count - 4`, when byte 4 is not `magic`, or when
    /// `innerLength < innerHeaderSize`.
    ///
    /// `OnDataReceived` calls `TryParse` once at offset 0 and ignores the
    /// consumed-byte count. It does not keep a leftover buffer. A callback
    /// that is not one complete frame is logged and dropped. Extra bytes
    /// after a valid frame in the same callback are not read.
    public struct Frame {
        public var messageType: UInt32
        public var sequence: UInt32
        public var payload: String

        public init(messageType: UInt32, sequence: UInt32, payload: String) {
            self.messageType = messageType
            self.sequence = sequence
            self.payload = payload
        }

        public init(messageType: MessageType, sequence: UInt32, payload: String) {
            self.init(messageType: messageType.rawValue, sequence: sequence, payload: payload)
        }

        /// `JsonMessage.Serialize`.
        public func encoded() -> Data {
            let payloadBytes = Data(payload.utf8)
            let innerLength = UInt32(HydraChannelProtocol.innerHeaderSize + payloadBytes.count)
            var encoded = Data(capacity: HydraChannelProtocol.totalHeaderSize + payloadBytes.count)
            appendUInt32LE(&encoded, innerLength)
            encoded.append(HydraChannelProtocol.magic)
            appendUInt32LE(&encoded, messageType)
            appendUInt32LE(&encoded, sequence)
            encoded.append(payloadBytes)
            return encoded
        }

        /// `JsonMessage.TryParse` at offset 0. Returns nil for the same cases
        /// the Windows parser rejects. Does not require the buffer to end at
        /// the frame; `consumed` is the frame size `TryParse` reports.
        public static func decode(_ buffer: Data) -> (frame: Frame, consumed: Int)? {
            guard buffer.count >= HydraChannelProtocol.totalHeaderSize else { return nil }
            let innerLength = readUInt32LE(buffer, 0)
            guard innerLength <= UInt32(buffer.count - 4) else { return nil }
            guard buffer[buffer.startIndex + 4] == HydraChannelProtocol.magic else { return nil }
            guard innerLength >= UInt32(HydraChannelProtocol.innerHeaderSize) else { return nil }
            let messageType = readUInt32LE(buffer, 5)
            let sequence = readUInt32LE(buffer, 9)
            let payloadCount = Int(innerLength) - HydraChannelProtocol.innerHeaderSize
            let payloadStart = buffer.startIndex + HydraChannelProtocol.totalHeaderSize
            let payloadEnd = payloadStart + payloadCount
            guard let payload = String(data: buffer[payloadStart..<payloadEnd], encoding: .utf8) else {
                return nil
            }
            let frame = Frame(messageType: messageType, sequence: sequence, payload: payload)
            return (frame, 4 + Int(innerLength))
        }
    }
}

/// Handshake implemented by `ChannelCallback.HandleAuthFrame` and
/// `RdpDvc.Shared.ChannelChallengeAuth`.
///
/// The channel secret is not a JSON field and is not written into the
/// diagnostic payload.
///
/// 1. The client starts in `awaitingChallengeRequest`.
/// 2. The session host sends `authChallengeRequest` (type 3). Any other type
///    closes the channel. The type 3 payload is not read.
/// 3. The client draws `nonceByteCount` random bytes, Base64-encodes them
///    with standard `Convert.ToBase64String` (padding, not URL-safe), and
///    sends `authChallenge` (type 4) whose entire payload is that string.
///    The sequence is 0. The request's sequence is not echoed.
/// 4. The client waits in `awaitingResponse`. The next frame must be
///    `authResponse` (type 5). Any other type closes the channel.
/// 5. The client checks that payload with `ChannelChallengeAuth.Verify`:
///    HMAC-SHA256, key = UTF-8 bytes of the channel-secret string,
///    data = UTF-8 bytes of the nonce string from step 3,
///    then standard Base64. `Verify` UTF-8-encodes both Base64 strings and
///    compares those bytes with `CryptographicOperations.FixedTimeEquals`.
///    A null payload fails before the compare. The secret itself is never
///    placed in the frame.
/// 6. On success the state becomes `authenticated`. Later frames are
///    accepted only when the type is `jsonRequest`. Other types are logged
///    and ignored. A failed check closes the channel.
///
/// After authentication, `HandleRequest` reads `cmd` and `param`:
///
/// - `init`: payload is `ClientInfo` JSON (`InitField`). Not the envelope.
/// - `fullinventory`: `JsonSerializer.Serialize<SystemInventory>(value, null)`.
/// - `location`: `Serialize<CollectionResult<LocationInfo>>`.
/// - `network`: `Serialize<NetworkDiagnosticsResult>`. A non-blank `param`
///   is a bandwidth-test URL string (`DiagnosticOptions.BandwidthTestUrl`),
///   not a JSON object. A blank or missing `param` uses the plugin's saved
///   ping settings.
/// - `performance`: `Serialize<IReadOnlyList<PerformanceSample>>`.
/// - `gettime`: envelope, status `Client time is ` + local `"O"` time.
/// - `ping`: envelope, status `Pong`.
/// - anything else: envelope, status `Client CPU Usage is ` + one decimal + ` %`.
///
/// `param` is passed into the inventory and location handlers and is not
/// stored by those async methods, so the recovered IL does not show them
/// reading it. Only `network` uses it.
///
/// The four collector payloads are serialized with a null
/// `JsonSerializerOptions`, so Windows property names are the CLR names in
/// PascalCase. Nothing in these two assemblies parses that JSON. The session
/// manager stores and forwards the response string. The Hydra agent displays
/// `SystemInventory`, `CollectionResult<LocationInfo>`,
/// `NetworkDiagnosticsResult`, and `PerformanceSample` from those names.
/// A payload that uses a different schema deserializes as an empty inventory.
/// The snapshot must not contain the channel secret.
///
/// Unknown, because the session-host read loop is not in the client MSI:
///
/// - Whether the host splits one frame across several DVC reads. The Windows
///   client does not reassemble. The length prefix is enough to reassemble
///   if the transport fragments a write.
/// - Whether the host accepts more than one frame in a single write. The
///   Windows client writes one frame per `IWTSVirtualChannel.Write` and, on
///   input, parses only the first frame in the callback.
/// - Which `cmd` the Hydra service sends for a routine pull, and whether a
///   component outside this MSI requires the Windows `SystemInventory`
///   property names. These assemblies do not.
/// - The bytes of an `authChallengeRequest` payload. The client ignores them.
/// - A product version the host requires in `InitField.version`.
public enum HydraChannelHandshake {
    public static let authChallengeSequence: UInt32 = 0
}

private func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    let bytes = data[start..<(start + 4)]
    return bytes.enumerated().reduce(UInt32(0)) { partial, item in
        partial | (UInt32(item.element) << (UInt32(item.offset) * 8))
    }
}

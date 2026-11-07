import Foundation

/// The framing of `*.channel.k8s.io` WebSocket messages: the first byte is
/// the channel, the rest is the payload.
public enum KubeChannelFrames {
    public static let v5Protocol = "v5.channel.k8s.io"
    public static let v4Protocol = "v4.channel.k8s.io"

    /// Exec channels.
    public static let stdin: UInt8 = 0
    public static let stdout: UInt8 = 1
    public static let stderr: UInt8 = 2
    public static let error: UInt8 = 3
    public static let resize: UInt8 = 4
    /// v5 only: a message `[255, channel]` closes that channel.
    public static let close: UInt8 = 255

    public static func encode(channel: UInt8, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 1)
        data.append(channel)
        data.append(payload)
        return data
    }

    public static func decode(_ message: Data) -> (channel: UInt8, payload: Data)? {
        guard let first = message.first else { return nil }
        return (first, Data(message.dropFirst()))
    }

    /// The resize message: `{"Width":cols,"Height":rows}` on channel 4.
    public static func resizeMessage(cols: Int, rows: Int) -> Data {
        encode(channel: resize, Data(#"{"Width":\#(max(1, cols)),"Height":\#(max(1, rows))}"#.utf8))
    }

    /// The v5 message that closes stdin.
    public static var closeStdinMessage: Data { Data([close, stdin]) }

    /// The result on the error channel: a `Status` object. Success gives exit
    /// code 0; `NonZeroExitCode` gives the code; other failures give a message.
    public static func execResult(_ payload: Data) -> (exitCode: Int?, message: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            let text = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text.isEmpty ? nil : text)
        }
        if object["status"] as? String == "Success" { return (0, nil) }
        let causes = (object["details"] as? [String: Any])?["causes"] as? [[String: Any]] ?? []
        let code = causes.first { $0["reason"] as? String == "ExitCode" }.flatMap { ($0["message"] as? String).flatMap { Int($0) } }
        if object["reason"] as? String == "NonZeroExitCode", let code { return (code, nil) }
        return (code, object["message"] as? String)
    }
}

/// Reads port-forward messages (portforward.k8s.io over v4.channel.k8s.io).
/// Port `i` of the request has data channel `2i` and error channel `2i+1`.
/// The kubelet sends the port (2 bytes, little-endian) as the first message
/// of each channel; newer API servers do not. A first message of exactly
/// those 2 bytes is dropped, any other message is payload.
public struct KubePortForwardDemux: Sendable {
    public enum Event: Equatable, Sendable {
        case data(Data)
        case error(String)
    }

    private let portBytes: Data
    private var seen: Set<UInt8> = []
    private var errorText: [UInt8: Data] = [:]

    public init(port: Int) {
        portBytes = Data([UInt8(port & 0xFF), UInt8((port >> 8) & 0xFF)])
    }

    /// The events in one message. A message of the port prefix alone gives none.
    public mutating func feed(_ message: Data) -> [Event] {
        guard let (channel, payload) = KubeChannelFrames.decode(message) else { return [] }
        if seen.insert(channel).inserted, payload == portBytes { return [] }
        guard !payload.isEmpty else { return [] }
        if channel % 2 == 0 { return [.data(payload)] }
        errorText[channel, default: Data()].append(payload)
        let text = String(decoding: errorText[channel] ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return [.error(text)]
    }

    /// A client message for the data channel of the first port.
    public static func dataMessage(_ payload: Data) -> Data {
        KubeChannelFrames.encode(channel: 0, payload)
    }
}

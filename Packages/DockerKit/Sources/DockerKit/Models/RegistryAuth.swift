import Foundation

/// Credentials for a registry, encoded into the `X-Registry-Auth` header.
///
/// Docker expects a base64url-encoded JSON object. Standard base64 with `+`/`/`
/// is rejected by some registries, so we use the URL-safe alphabet. Padding is
/// tolerated by the daemon and kept as produced by the encoder.
public struct RegistryAuth: Hashable, Sendable, Encodable {
    public var username: String
    public var password: String
    public var serverAddress: String

    enum CodingKeys: String, CodingKey {
        case username
        case password
        case serverAddress = "serveraddress"
    }

    public init(username: String, password: String, serverAddress: String = "") {
        self.username = username
        self.password = password
        self.serverAddress = serverAddress
    }

    /// Encodes the credentials into the URL-safe base64 value carried by the
    /// `X-Registry-Auth` request header.
    public func headerValue() throws -> String {
        let json = try JSONEncoder().encode(self)
        return json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

import Foundation

/// Credentials for a registry, encoded into the `X-Registry-Auth` header.
///
/// Docker expects a base64url-encoded JSON object. Standard base64 with `+`/`/`
/// is rejected by some registries, so we use the URL-safe alphabet. Padding is
/// tolerated by the daemon and kept as produced by the encoder.
///
/// Either username/password or an `identityToken` carries the secret: helpers
/// that return an OAuth2 token (username `<token>`) populate `identityToken`,
/// which Docker accepts in place of a password.
public struct RegistryAuth: Hashable, Sendable, Encodable {
    public var username: String
    public var password: String
    public var serverAddress: String
    /// OAuth2 identity token, used instead of username/password. Encoded as
    /// `identitytoken`; omitted from the header when nil.
    public var identityToken: String?

    enum CodingKeys: String, CodingKey {
        case username
        case password
        case serverAddress = "serveraddress"
        case identityToken = "identitytoken"
    }

    public init(
        username: String = "",
        password: String = "",
        serverAddress: String = "",
        identityToken: String? = nil
    ) {
        self.username = username
        self.password = password
        self.serverAddress = serverAddress
        self.identityToken = identityToken
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(serverAddress, forKey: .serverAddress)
        try container.encodeIfPresent(identityToken, forKey: .identityToken)
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

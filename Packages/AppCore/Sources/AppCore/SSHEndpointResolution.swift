import Foundation
import SSHKit

/// Connection parameters for an `SSHEndpoint` after consulting ~/.ssh/config.
///
/// Single source of truth for how a user-configured endpoint maps onto the
/// wire: the GUI (`HostSession`) and the headless paths (App Intents, MCP
/// server) must dial exactly the same host, so they all resolve through here.
public struct ResolvedSSHEndpoint: Sendable {
    public let hostName: String
    public let port: Int
    public let username: String
    public let identityFiles: [String]

    /// Resolves `endpoint` against ssh_config, filling any gaps the user left
    /// blank.
    public static func resolve(_ endpoint: SSHEndpoint) -> ResolvedSSHEndpoint {
        let resolved = SSHConfig.resolve(host: endpoint.host)

        // The configured host may be an ssh_config alias (Host mybox ->
        // HostName 203.0.113.7); always connect to the resolved HostName —
        // resolve() falls back to the input when no config entry matches.
        let hostName = resolved.hostName

        // Port 0 or 22 means "default": let ssh_config override it.
        let port = endpoint.port != 22 && endpoint.port != 0 ? endpoint.port : resolved.port

        let username: String = {
            if !endpoint.username.isEmpty { return endpoint.username }
            if let user = resolved.user, !user.isEmpty { return user }
            return NSUserName()
        }()

        return ResolvedSSHEndpoint(
            hostName: hostName,
            port: port,
            username: username,
            identityFiles: resolved.identityFiles
        )
    }
}

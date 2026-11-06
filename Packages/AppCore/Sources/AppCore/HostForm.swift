import Foundation
import Observation
import DockerKit

/// Parses a TCP port typed into a form field.
public enum PortInput: Equatable, Sendable {
    /// Nothing typed: the caller uses its default (ssh_config, 22, …).
    case empty
    case valid(Int)
    /// Not a whole number in 1–65535.
    case invalid

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            self = .empty
        } else if trimmed.allSatisfy(\.isASCII), let value = Int(trimmed), (1...65535).contains(value) {
            self = .valid(value)
        } else {
            self = .invalid
        }
    }

    public var value: Int? {
        if case .valid(let value) = self { return value }
        return nil
    }

    /// Inline message for an invalid port, nil otherwise.
    public var message: String? {
        self == .invalid
            ? String(localized: "Enter a port from 1 to 65535.", bundle: .module)
            : nil
    }
}

/// Checks of the SSH host field in the Add Host form.
public enum SSHHostInput {
    /// Inline message when `text` cannot be a host name, nil when it can (or
    /// when it is empty; the Add button handles that).
    public static func message(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("://") {
            return String(localized: "Enter a host name or address, not a URL.", bundle: .module)
        }
        if trimmed.contains("@") {
            return String(localized: "Put the user name in the User field.", bundle: .module)
        }
        if trimmed.contains(where: \.isWhitespace) {
            return String(localized: "A host name cannot contain spaces.", bundle: .module)
        }
        return nil
    }
}

/// What an SSH host in the Add Host form resolves to after ssh_config: the
/// values the connection will use.
public struct SSHConnectionSummary: Equatable, Sendable {
    public var destination: String
    /// The key file the connection tries first, or nil for the default keys.
    public var key: String?
    /// ProxyJump hops, outermost first, as `user@host:port`.
    public var jumps: [String]

    public init(endpoint: SSHEndpoint, configPath: String = "~/.ssh/config") {
        let resolved = ResolvedSSHEndpoint.resolve(endpoint, configPath: configPath)
        destination = "\(resolved.username)@\(resolved.hostName):\(resolved.port)"
        if case .keyFile(let path) = endpoint.auth, !path.isEmpty {
            key = (path as NSString).lastPathComponent
        } else if case .password = endpoint.auth {
            key = nil
        } else {
            key = resolved.identityFiles.first.map { ($0 as NSString).lastPathComponent }
        }
        jumps = resolved.jumps.map { "\($0.username)@\($0.hostName):\($0.port)" }
    }
}

/// "Test Connection" in the Add Host form: connects a throwaway session with
/// the same code as a real host, reports the outcome, then disconnects.
@MainActor
@Observable
public final class ConnectionTest {
    public enum State: Equatable, Sendable {
        case idle
        case testing
        case succeeded(SystemVersion)
        case failed(String)
    }

    public typealias Probe = @MainActor (HostSession) async -> State

    public private(set) var state: State = .idle
    /// The session under test, so the form can show its host key or
    /// passphrase prompt.
    public private(set) var session: HostSession?

    private let makeSession: @MainActor (DockerHost) -> HostSession
    private let probe: Probe
    private var task: Task<Void, Never>?
    /// Bumped by every start and cancel; a result from an older run is dropped.
    private var generation = 0

    public init(
        makeSession: @escaping @MainActor (DockerHost) -> HostSession = { HostSession(host: $0) },
        probe: @escaping Probe = ConnectionTest.connect
    ) {
        self.makeSession = makeSession
        self.probe = probe
    }

    public var isTesting: Bool { state == .testing }

    public func start(_ host: DockerHost) {
        stop()
        generation += 1
        let run = generation
        let session = makeSession(host)
        self.session = session
        state = .testing
        task = Task { [weak self] in
            let result = await self?.probe(session) ?? .idle
            await session.disconnect()
            guard let self, run == self.generation else { return }
            self.state = result
            self.session = nil
        }
    }

    /// Stops a running test and forgets its result (the form changed).
    public func reset() {
        stop()
        state = .idle
    }

    private func stop() {
        generation += 1
        task?.cancel()
        task = nil
        if let session {
            self.session = nil
            Task { await session.disconnect() }
        }
        if state == .testing { state = .idle }
    }

    /// The real probe: connect, read the outcome, keep nothing.
    public static func connect(_ session: HostSession) async -> State {
        await session.connect()
        switch session.status {
        case .connected(let version):
            return .succeeded(version)
        case .failed(let message):
            return .failed(message)
        case .connecting, .disconnected:
            return .failed(session.dockerNotInstalled
                ? String(localized: "Docker is not installed on this Mac.", bundle: .module)
                : String(localized: "The connection did not open.", bundle: .module))
        }
    }
}

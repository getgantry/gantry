import Foundation

/// Response from `POST /containers/{id}/exec`.
public struct ExecCreateResponse: Codable, Sendable {
    public var id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

/// Subset of `GET /exec/{id}/json` used to detect process completion.
public struct ExecInspect: Codable, Sendable {
    public var running: Bool
    public var exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case running = "Running"
        case exitCode = "ExitCode"
    }
}

/// Request body for `POST /containers/{id}/exec`.
private struct ExecCreateRequest: Encodable {
    var attachStdin = true
    var attachStdout = true
    var attachStderr = true
    var tty: Bool
    var cmd: [String]
    var workingDir: String?
    var user: String?
    var env: [String]?

    enum CodingKeys: String, CodingKey {
        case attachStdin = "AttachStdin"
        case attachStdout = "AttachStdout"
        case attachStderr = "AttachStderr"
        case tty = "Tty"
        case cmd = "Cmd"
        case workingDir = "WorkingDir"
        case user = "User"
        case env = "Env"
    }
}

/// Request body for `POST /exec/{id}/start`.
private struct ExecStartRequest: Encodable {
    var detach = false
    var tty: Bool

    enum CodingKeys: String, CodingKey {
        case detach = "Detach"
        case tty = "Tty"
    }
}

extension DockerClient {
    /// `POST /containers/{id}/exec` — creates an exec instance and returns its id.
    public func createExec(
        containerID: String,
        command: [String],
        tty: Bool = true,
        workingDir: String? = nil,
        user: String? = nil,
        env: [String]? = nil
    ) async throws -> String {
        let payload = ExecCreateRequest(
            tty: tty,
            cmd: command,
            workingDir: workingDir,
            user: user,
            env: env
        )
        let body = try JSONEncoder().encode(payload)
        let response = try await requestData(
            method: .post,
            path: "/containers/\(containerID)/exec",
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [200, 201]
        )
        return try decode(ExecCreateResponse.self, from: response.body, path: "/containers/\(containerID)/exec").id
    }

    /// `POST /exec/{id}/start` — starts an exec instance and hijacks the
    /// connection into a raw bidirectional byte channel.
    public func startExecHijacked(execID: String, tty: Bool = true) async throws -> DockerHijackedConnection {
        let body = try JSONEncoder().encode(ExecStartRequest(tty: tty))
        return try await hijack(
            path: "/exec/\(execID)/start",
            headers: [
                "Connection": "Upgrade",
                "Upgrade": "tcp",
                "Content-Type": "application/json"
            ],
            body: body
        )
    }

    /// `POST /exec/{id}/resize` — informs the TTY of a terminal size change.
    public func resizeExec(execID: String, width: Int, height: Int) async throws {
        _ = try await requestData(
            method: .post,
            path: "/exec/\(execID)/resize",
            query: [
                URLQueryItem(name: "w", value: String(width)),
                URLQueryItem(name: "h", value: String(height))
            ],
            expecting: [200, 201]
        )
    }

    /// `GET /exec/{id}/json` — inspects an exec instance (running state, exit code).
    public func inspectExec(execID: String) async throws -> ExecInspect {
        try await getJSON("/exec/\(execID)/json")
    }
}

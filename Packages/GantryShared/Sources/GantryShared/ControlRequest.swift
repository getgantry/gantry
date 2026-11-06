import Foundation

/// What a Control Center control asks the app to do.
public enum ControlAction: Equatable, Sendable {
    case setAppleServices(running: Bool)
    case setContainer(hostID: UUID, name: String, running: Bool)
}

/// A control request as a `gantry://control` URL. The sandboxed extension
/// cannot reach Docker, so it opens this URL and the app does the work. The
/// token comes from the snapshot: a web page cannot read it, so it cannot
/// stop a container through a link.
public struct ControlRequest: Equatable, Sendable {
    public var action: ControlAction
    public var token: String

    public init(action: ControlAction, token: String) {
        self.action = action
        self.token = token
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = SharedIdentifiers.urlScheme
        components.host = "control"
        var items = [URLQueryItem(name: "token", value: token)]
        switch action {
        case .setAppleServices(let running):
            items.append(URLQueryItem(name: "target", value: "apple-services"))
            items.append(URLQueryItem(name: "running", value: running ? "1" : "0"))
        case .setContainer(let hostID, let name, let running):
            items.append(URLQueryItem(name: "target", value: "container"))
            items.append(URLQueryItem(name: "host", value: hostID.uuidString))
            items.append(URLQueryItem(name: "name", value: name))
            items.append(URLQueryItem(name: "running", value: running ? "1" : "0"))
        }
        components.queryItems = items
        return components.url!
    }

    /// Parses a URL from ``url``. Returns nil for any other URL.
    public static func parse(_ url: URL) -> ControlRequest? {
        guard url.scheme == SharedIdentifiers.urlScheme, url.host == "control",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name] = value }
        }
        guard let token = values["token"], !token.isEmpty,
              let runningText = values["running"], runningText == "1" || runningText == "0" else { return nil }
        let running = runningText == "1"
        switch values["target"] {
        case "apple-services":
            return ControlRequest(action: .setAppleServices(running: running), token: token)
        case "container":
            guard let hostText = values["host"], let hostID = UUID(uuidString: hostText),
                  let name = values["name"], !name.isEmpty else { return nil }
            return ControlRequest(action: .setContainer(hostID: hostID, name: name, running: running), token: token)
        default:
            return nil
        }
    }

    /// True when the request carries the expected token.
    public func isAuthorized(expectedToken: String) -> Bool {
        !expectedToken.isEmpty && token == expectedToken
    }
}

import Foundation

/// One HTTP request to a registry or to the Docker Hub API.
public struct RegistryHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A registry reply. The header names are lowercase.
public struct RegistryHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

/// The network seam of the image search. Tests use a fake.
public protocol RegistryHTTP: Sendable {
    func send(_ request: RegistryHTTPRequest) async throws -> RegistryHTTPResponse
}

/// `URLSession` with no cookies, no cache and no stored credentials.
public struct URLSessionRegistryHTTP: RegistryHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: RegistryHTTPRequest) async throws -> RegistryHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: name)] = String(describing: value)
        }
        return RegistryHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

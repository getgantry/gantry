import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1

/// `DockerTransport` backed by a local unix domain socket, using AsyncHTTPClient.
///
/// AsyncHTTPClient addresses unix sockets through the
/// `http+unix://<percent-encoded-socket-path><uri>` URL form, where `uri`
/// is the request path plus query string.
public final class UnixSocketTransport: DockerTransport, Sendable {
    private let socketPath: String
    private let client: HTTPClient

    /// Maximum buffered response body for `execute`: 256 MB.
    private static let maxBodyBytes = 256 * 1024 * 1024

    public init(socketPath: String) {
        self.socketPath = socketPath
        var configuration = HTTPClient.Configuration()
        configuration.timeout = .init(connect: .seconds(5), read: nil)
        configuration.decompression = .disabled
        self.client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configuration
        )
    }

    public func execute(_ request: DockerRequest) async throws -> DockerResponse {
        let httpRequest = try makeRequest(request)
        do {
            let response = try await client.execute(httpRequest, timeout: .seconds(60))
            let buffer = try await response.body.collect(upTo: Self.maxBodyBytes)
            return DockerResponse(
                status: Int(response.status.code),
                headers: Self.headerDictionary(response.headers),
                body: Data(buffer.readableBytesView)
            )
        } catch let error as DockerError {
            throw error
        } catch {
            throw DockerError.connectionFailed(String(describing: error))
        }
    }

    public func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        let httpRequest = try makeRequest(request)
        let response: HTTPClientResponse
        do {
            // Effectively unbounded: follow-style endpoints stay open indefinitely.
            response = try await client.execute(httpRequest, timeout: .hours(24 * 365))
        } catch let error as DockerError {
            throw error
        } catch {
            throw DockerError.connectionFailed(String(describing: error))
        }

        let body = response.body
        let bytes = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for try await buffer in body {
                        continuation.yield(Data(buffer.readableBytesView))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DockerError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return DockerByteStream(
            status: Int(response.status.code),
            headers: Self.headerDictionary(response.headers),
            bytes: bytes
        )
    }

    public func shutdown() async {
        try? await client.shutdown()
    }

    // MARK: - Request construction

    private func makeRequest(_ request: DockerRequest) throws -> HTTPClientRequest {
        var httpRequest = HTTPClientRequest(url: try makeURL(for: request))
        httpRequest.method = HTTPMethod(rawValue: request.method.rawValue)

        httpRequest.headers.replaceOrAdd(name: "Host", value: "docker")
        for (name, value) in request.headers {
            httpRequest.headers.replaceOrAdd(name: name, value: value)
        }

        if let body = request.body {
            httpRequest.body = .bytes(ByteBuffer(bytes: body))
        }

        return httpRequest
    }

    private func makeURL(for request: DockerRequest) throws -> String {
        var components = URLComponents()
        components.path = request.path
        components.queryItems = request.query.isEmpty ? nil : request.query
        guard let uri = components.string else {
            throw DockerError.connectionFailed("Invalid request path: \(request.path)")
        }
        let encodedSocket = socketPath.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? socketPath
        return "http+unix://\(encodedSocket)\(uri)"
    }

    private static func headerDictionary(_ headers: HTTPHeaders) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = value
        }
        return result
    }
}

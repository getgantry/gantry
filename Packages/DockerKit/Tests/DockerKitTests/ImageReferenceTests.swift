import Foundation
import Testing
@testable import DockerKit

@Test(arguments: [
    ("nginx", "docker.io/library/nginx:latest"),
    ("nginx:alpine", "docker.io/library/nginx:alpine"),
    ("docker.io/library/nginx:alpine", "docker.io/library/nginx:alpine"),
    ("index.docker.io/library/nginx:1", "docker.io/library/nginx:1"),
    ("axllent/mailpit:v1.32.0", "docker.io/axllent/mailpit:v1.32.0"),
    ("ghcr.io/apple/containerization/vminit:0.53.0", "ghcr.io/apple/containerization/vminit:0.53.0"),
    ("localhost:5000/app", "localhost:5000/app:latest"),
    ("localhost/app:2", "localhost/app:2"),
    ("nginx@sha256:abc", "docker.io/library/nginx@sha256:abc")
])
func imageReferenceCanonical(_ text: String, _ expected: String) throws {
    let reference = try #require(ImageReference.parse(text))
    #expect(reference.canonical == expected)
}

@Test(arguments: ["", "sha256:0790692be935", String(repeating: "a", count: 64), "Nginx:1", "a//b", "nginx:", "x@y"])
func imageReferenceRejects(_ text: String) {
    #expect(ImageReference.parse(text) == nil)
}

@Test func imageReferenceParts() throws {
    let reference = try #require(ImageReference.parse("nginx:1.27@sha256:abc"))
    #expect(reference.tag == "1.27")
    #expect(reference.digest == "sha256:abc")
    #expect(reference.name == "docker.io/library/nginx")
    #expect(reference.apiHost == "registry-1.docker.io")
    #expect(ImageReference.parse("ghcr.io/a/b:1")?.apiHost == "ghcr.io")
}

// MARK: - Registry client

private actor FakeRegistry: RegistryHTTP {
    private(set) var requests: [URLRequest] = []
    private let answer: @Sendable (URLRequest) -> (Int, [String: String], Data)

    init(answer: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)) {
        self.answer = answer
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        let (status, headers, body) = answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (response, body)
    }
}

private let hubDigest = "sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"

@Test func registryClientFollowsBearerChallenge() async throws {
    let registry = FakeRegistry { request in
        if request.url?.host == "auth.docker.io" { return (200, [:], Data(#"{"token":"t1"}"#.utf8)) }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer t1" {
            return (200, ["Docker-Content-Digest": hubDigest], Data())
        }
        // Header copied from a live registry-1.docker.io answer.
        return (401, ["WWW-Authenticate": #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/alpine:pull""#], Data())
    }
    let client = RegistryManifestClient(http: registry)
    let digest = try await client.digest(for: try #require(ImageReference.parse("alpine:3.22")))
    #expect(digest == hubDigest)

    let requests = await registry.requests
    #expect(requests.count == 3)
    #expect(requests[0].httpMethod == "HEAD")
    #expect(requests[0].url?.absoluteString == "https://registry-1.docker.io/v2/library/alpine/manifests/3.22")
    #expect(requests[0].value(forHTTPHeaderField: "Accept")?.hasPrefix("application/vnd.oci.image.index.v1+json") == true)
    let token = try #require(requests[1].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    #expect(token.queryItems?.contains(URLQueryItem(name: "scope", value: "repository:library/alpine:pull")) == true)
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func registryClientSendsCredentialsToTokenService() async throws {
    let registry = FakeRegistry { request in
        if request.url?.host == "ghcr.io", request.url?.path == "/token" {
            return (200, [:], Data(#"{"access_token":"t2"}"#.utf8))
        }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer t2" {
            return (200, ["Docker-Content-Digest": hubDigest], Data())
        }
        return (401, ["WWW-Authenticate": #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:o/app:pull""#], Data())
    }
    let client = RegistryManifestClient(http: registry)
    let auth = RegistryAuth(username: "me", password: "pw", serverAddress: "ghcr.io")
    _ = try await client.digest(for: try #require(ImageReference.parse("ghcr.io/o/app:1")), credentials: auth)
    let requests = await registry.requests
    let expected = "Basic " + Data("me:pw".utf8).base64EncodedString()
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == expected)
    // The manifest request never carries the password.
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test(arguments: [(404, RegistryCheckError.notFound), (429, .rateLimited), (500, .http(500)), (403, .unauthorized)])
func registryClientMapsErrors(_ status: Int, _ expected: RegistryCheckError) async throws {
    let registry = FakeRegistry { _ in (status, [:], Data()) }
    let client = RegistryManifestClient(http: registry)
    await #expect(throws: expected) {
        _ = try await client.digest(for: try #require(ImageReference.parse("nginx")))
    }
}

@Test func registryClientWithoutChallengeIsUnauthorized() async throws {
    let registry = FakeRegistry { _ in (401, [:], Data()) }
    await #expect(throws: RegistryCheckError.unauthorized) {
        _ = try await RegistryManifestClient(http: registry).digest(for: try #require(ImageReference.parse("nginx")))
    }
}

@Test func authChallengeParsing() {
    #expect(AuthChallenge.parse(#"Basic realm="Registry""#) == .basic)
    #expect(AuthChallenge.parse(#"Bearer realm="https://r/token",service="r",scope="repository:a:pull,push""#)
        == .bearer(realm: "https://r/token", service: "r", scope: "repository:a:pull,push"))
    #expect(AuthChallenge.parse("Bearer service=x") == nil)
    #expect(AuthChallenge.parse("Negotiate") == nil)
}

import Foundation
import Testing
import DockerKit
@testable import AppCore

// Fixtures are cut from live replies of hub.docker.com and ghcr.io (2026-11-21).
private enum Live {
    static let hubSearch = #"{"count":296605,"next":"https://hub.docker.com/v2/search/repositories/?page=2&page_size=3&query=nginx","previous":"","results":[{"repo_name":"nginx","short_description":"Official build of Nginx.","star_count":21425,"pull_count":13616996008,"repo_owner":"","is_automated":false,"is_official":true},{"repo_name":"nginx/nginx-ingress","short_description":"NGINX and  NGINX Plus Ingress Controllers for Kubernetes","star_count":124,"pull_count":1088881702,"repo_owner":"","is_automated":false,"is_official":false}]}"#
    static let hubEmpty = #"{"count":0,"next":"","previous":"","results":[]}"#
    static let hubTags = #"{"count": 1, "next": null, "previous": null, "results": [{"images": [{"architecture": "amd64", "variant": null, "os": "linux", "size": 26055355, "last_pushed": "2026-11-18T17:17:52.2720678Z"}, {"architecture": "arm", "variant": "v7", "os": "linux", "size": 21756158, "last_pushed": "2026-11-18T19:51:23.639637336Z"}, {"architecture": "arm64", "variant": "v8", "os": "linux", "size": 25958644, "last_pushed": "2026-11-18T17:17:53.685579058Z"}], "last_updated": "2026-11-20T01:52:03.186066Z", "name": "stable-alpine3.24", "full_size": 26055355, "v2": true, "tag_status": "active", "tag_last_pushed": "2026-11-20T01:52:03.186066Z", "media_type": "application/vnd.oci.image.index.v1+json", "content_type": "image", "digest": "sha256:caf4e1e032a20f9c3c5e28fc7f25ffd768ad8677b4975c54193075997b3a97e3"}]}"#
    static let ghcrChallenge = #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:home-assistant/home-assistant:pull""#
    static let ghcrPage1 = #"{"name":"home-assistant/home-assistant","tags":["2021.5.0.dev20210427","2021.5.0.dev20210428","2021.5.0b0"]}"#
    static let ghcrLink = #"</v2/home-assistant/home-assistant/tags/list?last=2021.5.0b0&n=3>; rel="next""#
}

/// Records requests and answers them with a closure.
private final class FakeHTTP: ImageSearchHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RegistryHTTPRequest] = []
    private let responder: @Sendable (RegistryHTTPRequest) throws -> RegistryHTTPResponse

    init(_ responder: @escaping @Sendable (RegistryHTTPRequest) throws -> RegistryHTTPResponse) {
        self.responder = responder
    }

    var requests: [RegistryHTTPRequest] { lock.withLock { recorded } }

    func send(_ request: RegistryHTTPRequest) async throws -> RegistryHTTPResponse {
        lock.withLock { recorded.append(request) }
        return try responder(request)
    }
}

private func ok(_ json: String, headers: [String: String] = [:]) -> RegistryHTTPResponse {
    RegistryHTTPResponse(status: 200, headers: headers, body: Data(json.utf8))
}

@Suite struct DockerHubAPITests {
    @Test func searchParsesLiveReply() async throws {
        let http = FakeHTTP { _ in ok(Live.hubSearch) }
        let results = try await DockerHubAPI(http: http).search("nginx")
        #expect(results.map(\.name) == ["nginx", "nginx/nginx-ingress"])
        #expect(results[0].isOfficial)
        #expect(results[0].starCount == 21425)
        #expect(results[1].description.hasPrefix("NGINX and"))
        let url = try #require(http.requests.first?.url)
        #expect(url.host == "hub.docker.com")
        #expect(url.path == "/v2/search/repositories")
        #expect(url.query?.contains("query=nginx") == true)
    }

    @Test func searchEncodesTheQuery() {
        let url = DockerHubAPI.searchURL(query: "a b&c", pageSize: 5)
        #expect(url.absoluteString.contains("query=a%20b%26c"))
    }

    @Test func tagsParseDateSizeAndPlatforms() async throws {
        let http = FakeHTTP { _ in ok(Live.hubTags) }
        let tags = try await DockerHubAPI(http: http).tags(repository: "nginx")
        #expect(http.requests.first?.url.path == "/v2/repositories/library/nginx/tags")
        let tag = try #require(tags.first)
        #expect(tag.name == "stable-alpine3.24")
        #expect(tag.lastPushed == DockerHubAPI.parseDate("2026-11-20T01:52:03.186066Z"))
        #expect(tag.lastPushed != nil)
        #expect(tag.platforms.map(\.display) == ["linux/amd64", "linux/arm/v7", "linux/arm64/v8"])
        #expect(tag.size(for: "linux/arm64") == 25958644)
        #expect(tag.size(for: nil) == 26055355)
        #expect(tag.supports("linux/arm64"))
        #expect(!tag.supports("linux/riscv64"))
        #expect(tag.supports(nil))
    }

    @Test func tagsOfUserRepositoryKeepNamespace() {
        #expect(DockerHubAPI.tagsURL(repository: "grafana/grafana", pageSize: 10).path == "/v2/repositories/grafana/grafana/tags")
    }

    @Test func emptyResultParses() throws {
        #expect(try DockerHubAPI.parseSearch(Data(Live.hubEmpty.utf8)).isEmpty)
    }

    @Test func rateLimitCarriesResetDate() async {
        let http = FakeHTTP { _ in RegistryHTTPResponse(status: 429, headers: ["X-RateLimit-Reset": "4102444800"]) }
        await #expect(throws: ImageSearchError.rateLimited(retryAfter: Date(timeIntervalSince1970: 4102444800))) {
            _ = try await DockerHubAPI(http: http).search("nginx")
        }
    }

    @Test func offlineMapsURLError() async {
        let http = FakeHTTP { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: ImageSearchError.offline) {
            _ = try await DockerHubAPI(http: http).search("nginx")
        }
    }
}

@Suite struct ImageSearchErrorTests {
    @Test func engineMessagesMap() {
        #expect(ImageSearchError.from(DockerError.apiError(status: 500, message: "toomanyrequests: You have reached your pull rate limit")) == .rateLimited(retryAfter: nil))
        #expect(ImageSearchError.from(DockerError.apiError(status: 500, message: "Get \"https://index.docker.io/v1/search\": dial tcp: lookup index.docker.io: no such host")) == .offline)
        // Live reply of nettop with no default route (2026-11-21).
        let nettop = #"Get "https://index.docker.io/v1/search?q=nginx&n=5": dial tcp: lookup index.docker.io on 127.0.0.53:53: server misbehaving"#
        #expect(ImageSearchError.from(DockerError.apiError(status: 500, message: nettop)) == .offline)
        #expect(ImageSearchError.from(DockerError.apiError(status: 500, message: "boom")) == .failed("boom"))
    }

    @Test func statusesMap() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(ImageSearchError.from(status: 429, headers: ["retry-after": "30"], now: now) == .rateLimited(retryAfter: Date(timeIntervalSince1970: 1030)))
        #expect(ImageSearchError.from(status: 429, headers: ["x-ratelimit-reset": "10"], now: now) == .rateLimited(retryAfter: nil))
        #expect(ImageSearchError.from(status: 404, headers: [:]) == .notFound)
        #expect(ImageSearchError.from(status: 401, headers: [:]) == .unauthorized)
        #expect(ImageSearchError.from(status: 502, headers: [:]) == .failed("HTTP 502"))
    }

    @Test func urlErrorsMap() {
        #expect(ImageSearchError.from(URLError(.timedOut)) == .offline)
        #expect(ImageSearchError.from(URLError(.cannotFindHost)) == .offline)
        if case .failed = ImageSearchError.from(URLError(.badServerResponse)) {} else {
            Issue.record("expected failed")
        }
    }
}

@Suite struct RegistryRepositoryTests {
    @Test func parsesReferences() throws {
        let ghcr = try #require(RegistryRepository("ghcr.io/home-assistant/home-assistant:stable"))
        #expect(ghcr.registryHost == "ghcr.io")
        #expect(ghcr.path == "home-assistant/home-assistant")
        #expect(ghcr.pullName == "ghcr.io/home-assistant/home-assistant")

        let hub = try #require(RegistryRepository("nginx:latest"))
        #expect(hub.registryHost == "registry-1.docker.io")
        #expect(hub.path == "library/nginx")
        #expect(hub.pullName == "nginx")
        #expect(hub.isDockerHub)

        let explicit = try #require(RegistryRepository("docker.io/grafana/grafana"))
        #expect(explicit.path == "grafana/grafana")
        #expect(explicit.pullName == "grafana/grafana")

        let local = try #require(RegistryRepository("localhost:5000/app@sha256:abc"))
        #expect(local.registryHost == "localhost:5000")
        #expect(local.path == "app")
        #expect(RegistryTagsAPI.firstPageURL(local)?.absoluteString == "http://localhost:5000/v2/app/tags/list?n=1000")
    }

    @Test func rejectsBadText() {
        #expect(RegistryRepository("") == nil)
        #expect(RegistryRepository("ghcr.io") == nil)
        #expect(RegistryRepository("two words") == nil)
    }
}

@Suite struct RegistryTagsAPITests {
    @Test func anonymousTokenFlowAndPages() async throws {
        let http = FakeHTTP { request in
            let url = request.url
            if url.host == "ghcr.io", url.path == "/token" {
                return ok(#"{"token":"anon"}"#)
            }
            guard request.headers["Authorization"] == "Bearer anon" else {
                return RegistryHTTPResponse(status: 401, headers: ["WWW-Authenticate": Live.ghcrChallenge])
            }
            if url.query?.contains("last=") == true {
                return ok(#"{"tags":["latest","2021.10.1"]}"#)
            }
            return ok(Live.ghcrPage1, headers: ["Link": Live.ghcrLink])
        }
        // The store is asked only after the 401; it has no login here.
        let quiet = RegistryTagsAPI(http: http) { _ in nil }
        let repository = try #require(RegistryRepository("ghcr.io/home-assistant/home-assistant"))
        let tags = try await quiet.tags(repository).map(\.name)
        #expect(tags.first == "latest")
        #expect(tags.contains("2021.10.1"))
        #expect(tags.count == 5)
        let token = try #require(http.requests.first { $0.url.path == "/token" })
        #expect(token.url.query?.contains("service=ghcr.io") == true)
        #expect(token.url.query?.contains("scope=repository:home-assistant/home-assistant:pull") == true)
        #expect(token.headers["Authorization"] == nil)
        #expect(http.requests.allSatisfy { $0.url.host == "ghcr.io" })
    }

    @Test func basicCredentialsGoToTheRealm() async throws {
        let http = FakeHTTP { request in
            if request.url.path == "/token" {
                return request.headers["Authorization"] == "Basic dTpw" ? ok(#"{"access_token":"t"}"#) : RegistryHTTPResponse(status: 401)
            }
            if request.headers["Authorization"] == "Bearer t" { return ok(#"{"tags":["1.0"]}"#) }
            return RegistryHTTPResponse(status: 401, headers: ["www-authenticate": #"Bearer realm="https://reg.example/token",service="reg.example""#])
        }
        let api = RegistryTagsAPI(http: http) { reference in
            #expect(reference == "reg.example/team/app")
            return RegistryAuth(username: "u", password: "p", serverAddress: "reg.example")
        }
        let tags = try await api.tags(#require(RegistryRepository("reg.example/team/app")))
        #expect(tags.map(\.name) == ["1.0"])
    }

    @Test func identityTokenUsesRefreshGrant() async throws {
        let http = FakeHTTP { request in
            if request.url.path == "/token" {
                let form = String(decoding: request.body ?? Data(), as: UTF8.self)
                return request.method == "POST" && form.contains("grant_type=refresh_token") && form.contains("refresh_token=idt")
                    ? ok(#"{"access_token":"t"}"#) : RegistryHTTPResponse(status: 400)
            }
            if request.headers["Authorization"] == "Bearer t" { return ok(#"{"tags":["v1"]}"#) }
            return RegistryHTTPResponse(status: 401, headers: ["www-authenticate": #"Bearer realm="https://reg.example/token""#])
        }
        let api = RegistryTagsAPI(http: http) { _ in RegistryAuth(serverAddress: "reg.example", identityToken: "idt") }
        #expect(try await api.tags(#require(RegistryRepository("reg.example/app"))).map(\.name) == ["v1"])
    }

    @Test func plainHTTPRealmIsRefused() async throws {
        let http = FakeHTTP { _ in
            RegistryHTTPResponse(status: 401, headers: ["www-authenticate": #"Bearer realm="http://evil.example/token""#])
        }
        let api = RegistryTagsAPI(http: http) { _ in RegistryAuth(username: "u", password: "p", serverAddress: "x") }
        await #expect(throws: ImageSearchError.unauthorized) {
            _ = try await api.tags(#require(RegistryRepository("reg.example/app")))
        }
        #expect(http.requests.allSatisfy { $0.url.host == "reg.example" })
    }

    @Test func missingRepositoryIsNotFound() async throws {
        let http = FakeHTTP { _ in RegistryHTTPResponse(status: 404) }
        let api = RegistryTagsAPI(http: http) { _ in nil }
        await #expect(throws: ImageSearchError.notFound) {
            _ = try await api.tags(#require(RegistryRepository("quay.io/none/none")))
        }
    }

    @Test func helpers() {
        let base = URL(string: "https://ghcr.io/v2/a/tags/list?n=1000")!
        #expect(RegistryTagsAPI.nextPageURL(link: Live.ghcrLink, base: base)?.absoluteString == "https://ghcr.io/v2/home-assistant/home-assistant/tags/list?last=2021.5.0b0&n=3")
        #expect(RegistryTagsAPI.nextPageURL(link: "<https://other.example/v2/x>; rel=\"next\"", base: base) == nil)
        #expect(RegistryTagsAPI.sorted(["1.2", "1.10", "latest", "1.9"]) == ["latest", "1.10", "1.9", "1.2"])
        let digest = String(repeating: "ab", count: 32)
        #expect(RegistryTagsAPI.sorted(["sha256-\(digest).sig", "sha256-\(digest)", "1.0", "sha256-x"]) == ["sha256-x", "1.0"])
        #expect(AuthChallenge(Live.ghcrChallenge)?.parameters["realm"] == "https://ghcr.io/token")
        #expect(AuthChallenge(#"Basic realm="Registry""#)?.scheme == "basic")
    }
}

@MainActor
@Suite struct ImageSearchModelTests {
    /// Counts the searches; the debounce sleep returns at once.
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var queries: [String] = []
        var repositories: [String] = []
        func add(query: String) { lock.withLock { queries.append(query) } }
        func add(repository: String) { lock.withLock { repositories.append(repository) } }
    }

    private func makeModel(
        calls: Calls,
        search: @escaping @Sendable (String) async throws -> [ImageSearchResult] = { _ in [] },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> ImageSearchModel {
        ImageSearchModel(
            services: .init(
                search: { query in calls.add(query: query); return try await search(query) },
                hubTags: { repository in calls.add(repository: repository); return [ImageTag(name: "latest")] },
                registryTags: { repository in calls.add(repository: repository.pullName); return [ImageTag(name: "v1")] },
                sleep: sleep
            ),
            hostPlatform: "linux/arm64"
        )
    }

    @Test func debounceSendsOnlyTheLastText() async {
        let calls = Calls()
        let model = makeModel(calls: calls, search: { query in
            [ImageSearchResult(name: query, description: "", starCount: 1, isOfficial: false)]
        })
        model.setQuery("n")
        model.setQuery("ng")
        model.setQuery("nginx")
        await model.searchTask?.value
        #expect(calls.queries == ["nginx"])
        #expect(model.results.map(\.name) == ["nginx"])
        #expect(model.phase == .loaded)
    }

    @Test func debounceWaitsThreeHundredMilliseconds() async {
        let slept = Calls()
        let model = makeModel(calls: Calls(), sleep: { duration in slept.add(query: "\(duration)") })
        model.setQuery("redis")
        await model.searchTask?.value
        #expect(slept.queries == ["\(Duration.milliseconds(300))"])
    }

    @Test func emptyTextClearsWithoutRequest() async {
        let calls = Calls()
        let model = makeModel(calls: calls)
        model.setQuery("   ")
        await model.searchTask?.value
        #expect(calls.queries.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func noResultsAndErrors() async {
        let model = makeModel(calls: Calls())
        model.setQuery("zzqq")
        await model.searchTask?.value
        #expect(model.phase == .empty)

        let failing = makeModel(calls: Calls(), search: { _ in throw URLError(.notConnectedToInternet) })
        failing.setQuery("nginx")
        await failing.searchTask?.value
        #expect(failing.phase == .failed(.offline))
    }

    @Test func officialResultsFirst() {
        let ranked = ImageSearchModel.ranked([
            ImageSearchResult(name: "a", description: "", starCount: 900, isOfficial: false),
            ImageSearchResult(name: "b", description: "", starCount: 5, isOfficial: true),
            ImageSearchResult(name: "c", description: "", starCount: 950, isOfficial: false)
        ])
        #expect(ranked.map(\.name) == ["b", "c", "a"])
    }

    @Test func selectLoadsHubTagsAndPullReference() async throws {
        let calls = Calls()
        let model = makeModel(calls: calls)
        model.select(ImageSearchResult(name: "nginx", description: "", starCount: 0, isOfficial: true))
        await model.tagsTask?.value
        #expect(calls.repositories == ["nginx"])
        let tag = try #require(model.tags.first)
        #expect(model.pullReference(for: tag) == "nginx:latest")
        #expect(model.tagsPhase == .loaded)
    }

    @Test func registrySourceListsTagsWithoutSearch() async throws {
        let calls = Calls()
        let model = makeModel(calls: calls)
        model.setSource(.registry)
        model.setQuery("ghcr.io/home-assistant/home-assistant")
        await model.searchTask?.value
        await model.tagsTask?.value
        #expect(calls.queries.isEmpty)
        #expect(calls.repositories == ["ghcr.io/home-assistant/home-assistant"])
        #expect(model.pullReference(for: try #require(model.tags.first)) == "ghcr.io/home-assistant/home-assistant:v1")
    }
}

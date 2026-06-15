import Foundation
import Testing
@testable import AppCore
import DockerKit

@Suite("Registry credential resolution")
struct RegistryCredentialStoreTests {
    // MARK: - Registry domain extraction

    @Test("Official images map to docker.io")
    func officialImagesMapToHub() {
        #expect(RegistryCredentialStore.registryDomain(forImageReference: "nginx") == "docker.io")
        #expect(RegistryCredentialStore.registryDomain(forImageReference: "nginx:latest") == "docker.io")
        #expect(RegistryCredentialStore.registryDomain(forImageReference: "library/nginx") == "docker.io")
        #expect(RegistryCredentialStore.registryDomain(forImageReference: "user/repo:tag") == "docker.io")
    }

    @Test("A host-like first segment is the registry")
    func registryHostsAreRecognized() {
        #expect(RegistryCredentialStore.registryDomain(forImageReference: "ghcr.io/owner/app:1.0") == "ghcr.io")
        #expect(
            RegistryCredentialStore.registryDomain(forImageReference: "registry.example.com:5000/app")
                == "registry.example.com:5000"
        )
        #expect(RegistryCredentialStore.registryDomain(forImageReference: "localhost:5000/app") == "localhost:5000")
        #expect(RegistryCredentialStore.registryDomain(forImageReference: "localhost/app") == "localhost")
    }

    // MARK: - Basic auth decoding

    @Test("Base64 username:password decodes, password may contain colons")
    func decodeBasicAuth() {
        let encoded = Data("alice:s3cr3t".utf8).base64EncodedString()
        let creds = RegistryCredentialStore.decodeBasic(encoded)
        #expect(creds?.user == "alice")
        #expect(creds?.password == "s3cr3t")

        let colonPw = Data("bob:a:b:c".utf8).base64EncodedString()
        let creds2 = RegistryCredentialStore.decodeBasic(colonPw)
        #expect(creds2?.user == "bob")
        #expect(creds2?.password == "a:b:c")

        #expect(RegistryCredentialStore.decodeBasic("not base64 $$$") == nil)
    }

    @Test("Docker Hub lookup keys include the historical index URL")
    func hubLookupKeys() {
        let keys = RegistryCredentialStore.lookupKeys(forDomain: "docker.io")
        #expect(keys.contains("https://index.docker.io/v1/"))
    }

    // MARK: - End-to-end resolution against a temp config

    private func writeConfig(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Inline auths entry resolves to username/password")
    func inlineAuthsResolves() async throws {
        let encoded = Data("alice:s3cr3t".utf8).base64EncodedString()
        let url = try writeConfig(#"{"auths":{"ghcr.io":{"auth":"\#(encoded)"}}}"#)
        let store = RegistryCredentialStore(configURL: url) { _, _ in nil }

        let auth = await store.auth(forImageReference: "ghcr.io/owner/app:1.0")
        #expect(auth?.username == "alice")
        #expect(auth?.password == "s3cr3t")
        #expect(auth?.serverAddress == "ghcr.io")
        #expect(auth?.identityToken == nil)
    }

    @Test("Docker Hub image resolves via the index URL key")
    func dockerHubResolves() async throws {
        let encoded = Data("hubuser:hubpass".utf8).base64EncodedString()
        let url = try writeConfig(#"{"auths":{"https://index.docker.io/v1/":{"auth":"\#(encoded)"}}}"#)
        let store = RegistryCredentialStore(configURL: url) { _, _ in nil }

        let auth = await store.auth(forImageReference: "nginx:latest")
        #expect(auth?.username == "hubuser")
        #expect(auth?.serverAddress == "https://index.docker.io/v1/")
    }

    @Test("Per-registry credHelper is consulted and wins over inline auths")
    func credHelperResolves() async throws {
        let url = try writeConfig(#"{"credHelpers":{"ghcr.io":"ghcrhelper"}}"#)
        let store = RegistryCredentialStore(configURL: url) { helper, server in
            #expect(helper == "ghcrhelper")
            #expect(server == "ghcr.io")
            return .init(username: "tokenuser", secret: "deadbeef")
        }

        let auth = await store.auth(forImageReference: "ghcr.io/owner/app")
        #expect(auth?.username == "tokenuser")
        #expect(auth?.password == "deadbeef")
    }

    @Test("Empty inline entry falls through to the global credsStore")
    func credsStoreFallback() async throws {
        let url = try writeConfig(#"{"auths":{"ghcr.io":{}},"credsStore":"osxkeychain"}"#)
        let store = RegistryCredentialStore(configURL: url) { helper, _ in
            #expect(helper == "osxkeychain")
            return .init(username: "keychainuser", secret: "kcpass")
        }

        let auth = await store.auth(forImageReference: "ghcr.io/owner/app")
        #expect(auth?.username == "keychainuser")
        #expect(auth?.password == "kcpass")
    }

    @Test("Helper username <token> yields an identity token")
    func identityTokenFromHelper() async throws {
        let url = try writeConfig(#"{"credsStore":"osxkeychain"}"#)
        let store = RegistryCredentialStore(configURL: url) { _, _ in
            .init(username: "<token>", secret: "oauth-token-value")
        }

        let auth = await store.auth(forImageReference: "ghcr.io/owner/app")
        #expect(auth?.identityToken == "oauth-token-value")
        #expect(auth?.username == "")
        #expect(auth?.password == "")
    }

    @Test("A missing config yields no credentials")
    func missingConfigYieldsNil() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
        let store = RegistryCredentialStore(configURL: url) { _, _ in nil }
        let auth = await store.auth(forImageReference: "ghcr.io/owner/app")
        #expect(auth == nil)
    }

    @Test("An unmatched registry yields no credentials (anonymous pull)")
    func unmatchedRegistryYieldsNil() async throws {
        let encoded = Data("alice:s3cr3t".utf8).base64EncodedString()
        let url = try writeConfig(#"{"auths":{"ghcr.io":{"auth":"\#(encoded)"}}}"#)
        let store = RegistryCredentialStore(configURL: url) { _, _ in nil }
        let auth = await store.auth(forImageReference: "quay.io/owner/app")
        #expect(auth == nil)
    }

    // MARK: - Header encoding

    @Test("Identity token is encoded into the X-Registry-Auth header")
    func headerEncodesIdentityToken() throws {
        let auth = RegistryAuth(serverAddress: "ghcr.io", identityToken: "abc")
        let header = try auth.headerValue()
        // base64url: no + or / in the output.
        #expect(!header.contains("+"))
        #expect(!header.contains("/"))
        let normalized = header
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let data = try #require(Data(base64Encoded: normalized))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["identitytoken"] as? String == "abc")
    }
}

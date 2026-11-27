import Foundation
import DockerKit

extension HostSession {
    /// `os/arch` of the host for a pull: `linux/<arch>` on Apple hosts (the
    /// guest is Linux), the daemon's `OSType/Architecture` on Docker hosts.
    public var pullPlatform: String? {
        guard let info else { return nil }
        let os = host.isAppleContainer ? "linux" : info.osType
        return ImageScanPlan.platformString(os: os, architecture: info.architecture)
    }

    /// Searches Docker Hub: through the Engine (`GET /images/search`) on
    /// Docker hosts, through the Docker Hub HTTP API on Apple hosts.
    public func searchImages(_ query: String, http: any ImageSearchHTTP) async throws -> [ImageSearchResult] {
        if host.isAppleContainer {
            return try await DockerHubAPI(http: http).search(query)
        }
        guard let client else {
            throw ImageSearchError.failed(String(localized: "Not connected", bundle: .module))
        }
        do {
            return try await client.searchImages(term: query)
        } catch {
            throw ImageSearchError.from(error)
        }
    }

    /// A search model wired to this host, Docker Hub and the registries.
    /// Credentials come from `RegistryCredentialStore`, only after a 401.
    public func makeImageSearchModel(http: any ImageSearchHTTP = URLSessionImageSearchHTTP()) -> ImageSearchModel {
        let store = RegistryCredentialStore()
        let registryAPI = RegistryTagsAPI(http: http) { reference in
            await store.auth(forImageReference: reference)
        }
        let hubAPI = DockerHubAPI(http: http)
        let services = ImageSearchModel.Services(
            search: { [weak self] query in
                guard let self else { throw CancellationError() }
                return try await self.searchImages(query, http: http)
            },
            hubTags: { repository in
                do {
                    return try await hubAPI.tags(repository: repository)
                } catch let error as ImageSearchError where error == .notFound || error == .unauthorized {
                    // A private Docker Hub repository: the registry API with the stored login.
                    guard let repo = RegistryRepository(repository), await store.auth(forImageReference: repository) != nil else {
                        throw error
                    }
                    return try await registryAPI.tags(repo)
                }
            },
            registryTags: { repository in try await registryAPI.tags(repository) }
        )
        return ImageSearchModel(services: services, hostPlatform: pullPlatform)
    }
}

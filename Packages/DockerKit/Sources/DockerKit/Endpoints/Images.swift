import Foundation

extension DockerClient {
    /// `GET /images/json`, enriched with each image's platform
    /// (architecture/OS). The manifest descriptor (`manifests=true`, Engine
    /// API 1.48+) is a cheap first source but current daemons leave its
    /// `platform` empty for images pulled by digest resolution, so summaries
    /// without a platform get a parallel `GET /images/{id}/json` round. Images
    /// whose inspect fails keep empty architecture (no badge, no error).
    public func listImages() async throws -> [ImageSummary] {
        var images: [ImageSummary] = try await getJSON(
            "/images/json",
            query: [URLQueryItem(name: "manifests", value: "true")]
        )
        try await fillMissingPlatforms(&images, inspecting: { _ in true })
        return images
    }

    /// `GET /images/json` with platforms filled in only for the images named
    /// by `ids` (one inspect per id), for callers that need architectures for
    /// a subset rather than the whole library.
    public func listImages(platformsFor ids: Set<String>) async throws -> [ImageSummary] {
        var images: [ImageSummary] = try await getJSON(
            "/images/json",
            query: [URLQueryItem(name: "manifests", value: "true")]
        )
        try await fillMissingPlatforms(&images) { ids.contains($0.id) }
        return images
    }

    /// `GET /images/{id}/json` returning the raw body for the Inspect tab.
    public func rawInspectImage(id: String) async throws -> Data {
        try await rawJSON(path: "/images/\(id)/json")
    }

    /// Inspects the selected images in parallel and writes each platform back
    /// into its summary's descriptor. Failures leave the descriptor empty.
    private func fillMissingPlatforms(
        _ images: inout [ImageSummary],
        inspecting shouldInspect: (ImageSummary) -> Bool
    ) async throws {
        let targets = images.enumerated().filter { shouldInspect($0.element) && $0.element.architecture.isEmpty }
        guard !targets.isEmpty else { return }
        try await withThrowingTaskGroup(of: (Int, ImagePlatform?).self) { group in
            for (index, image) in targets {
                group.addTask { (index, try? await self.imagePlatform(id: image.id)) }
            }
            for try await (index, platform) in group {
                if let platform {
                    images[index].descriptor = ImageDescriptor(platform: platform)
                }
            }
        }
    }

    /// Architecture and OS from a single image inspect.
    private func imagePlatform(id: String) async throws -> ImagePlatform {
        try await getJSON("/images/\(id)/json")
    }

    /// `DELETE /images/{id}`. Returns 200 with a delete report we ignore.
    public func removeImage(id: String, force: Bool = false) async throws {
        _ = try await requestData(
            method: .delete,
            path: "/images/\(id)",
            query: [URLQueryItem(name: "force", value: force ? "true" : "false")],
            expecting: [200]
        )
    }
}

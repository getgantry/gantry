import Foundation

extension DockerClient {
    /// `GET /distribution/{name}/json`: the daemon asks the registry for the
    /// manifest of `reference` and returns its descriptor digest.
    public func distributionDigest(reference: String, auth: RegistryAuth? = nil) async throws -> String {
        var headers: [String: String] = [:]
        if let auth { headers["X-Registry-Auth"] = try auth.headerValue() }
        let response = try await requestData(
            method: .get, path: "/distribution/\(reference)/json", headers: headers, expecting: [200]
        )
        let body = try decode(DistributionInspect.self, from: response.body, path: "/distribution")
        guard !body.descriptor.digest.isEmpty else {
            throw DockerError.decodingFailed("/distribution: no digest")
        }
        return body.descriptor.digest
    }
}

/// The part of the `/distribution` answer that Gantry reads.
struct DistributionInspect: Decodable {
    struct Descriptor: Decodable {
        var digest: String
    }
    var descriptor: Descriptor

    enum CodingKeys: String, CodingKey {
        case descriptor = "Descriptor"
    }
}

import Foundation

/// One line of output from an image build, as surfaced to the UI.
///
/// The Docker `/build` endpoint streams newline-delimited JSON objects; the
/// apple/container CLI streams plain text. Both are flattened into this shape so
/// the UI renders a single live log regardless of the host engine.
public struct BuildLogLine: Sendable, Equatable {
    /// Human-readable log text (a build step, layer status, or CLI output).
    public var text: String
    /// Whether this line reports a build failure.
    public var isError: Bool
    /// The resulting image id, set on the terminal `aux` line of a daemon build.
    public var imageID: String?

    public init(text: String, isError: Bool = false, imageID: String? = nil) {
        self.text = text
        self.isError = isError
        self.imageID = imageID
    }
}

/// Decodes a single JSON object from the Docker `/build` progress stream.
///
/// The daemon emits `{"stream": "..."}` for normal output, `{"aux": {"ID": …}}`
/// with the final image id, and `{"error": "...", "errorDetail": {...}}` on
/// failure.
struct BuildResponseLine: Decodable {
    struct Aux: Decodable {
        let id: String?
        enum CodingKeys: String, CodingKey { case id = "ID" }
    }

    let stream: String?
    let error: String?
    let aux: Aux?

    /// Maps a decoded daemon line onto a `BuildLogLine`, or nil for lines that
    /// carry no user-visible content (e.g. empty keep-alives).
    func asLogLine() -> BuildLogLine? {
        if let error, !error.isEmpty {
            return BuildLogLine(text: error, isError: true)
        }
        if let id = aux?.id, !id.isEmpty {
            return BuildLogLine(text: "", imageID: id)
        }
        if let stream, !stream.isEmpty {
            return BuildLogLine(text: stream)
        }
        return nil
    }
}

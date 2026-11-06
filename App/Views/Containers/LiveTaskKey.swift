import DockerKit

/// The `.task(id:)` key for live container views (logs, stats, processes).
/// It holds the running state too, so a stream that ended when the container
/// stopped starts again when the container starts, without a reselect.
struct LiveTaskKey: Hashable {
    let containerID: String
    let isRunning: Bool
}

extension ContainerSummary {
    var liveTaskKey: LiveTaskKey {
        LiveTaskKey(containerID: id, isRunning: state.isRunning)
    }
}

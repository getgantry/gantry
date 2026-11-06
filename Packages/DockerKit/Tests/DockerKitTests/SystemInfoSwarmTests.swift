import Foundation
import Testing
@testable import DockerKit

@Suite struct SystemInfoSwarmTests {
    private func decode(_ json: String) throws -> SystemInfo {
        try JSONDecoder().decode(SystemInfo.self, from: Data(json.utf8))
    }

    @Test func activeSwarmNode() throws {
        let info = try decode(#"{"NCPU":4,"Swarm":{"LocalNodeState":"active","NodeID":"x"}}"#)
        #expect(info.swarmActive)
        #expect(info.ncpu == 4)
    }

    @Test func inactiveOrMissingSwarm() throws {
        #expect(try !decode(#"{"Swarm":{"LocalNodeState":"inactive"}}"#).swarmActive)
        #expect(try !decode(#"{"Swarm":{}}"#).swarmActive)
        #expect(try !decode(#"{}"#).swarmActive)
    }
}

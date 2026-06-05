import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@Suite struct ContainerPromptTests {
    private func summary(
        state: String = "running",
        status: String = "Up 2 hours (unhealthy)"
    ) -> ContainerSummary {
        let json = """
        {"Id":"dbc5c115e83f0123456789","Names":["/web"],"Image":"nginx:alpine",\
        "State":"\(state)","Status":"\(status)",\
        "Ports":[{"PrivatePort":80,"PublicPort":8085,"Type":"tcp"}],\
        "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web"},\
        "Command":"nginx -g daemon off;"}
        """
        return try! JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    @Test func sshHostPromptCarriesReachabilityAndIdentity() {
        let id = UUID()
        let host = DockerHost(
            id: id,
            name: "Nettop",
            kind: .ssh(SSHEndpoint(host: "nettop.local", port: 1022, username: "andrew"))
        )
        let prompt = ContainerPrompt.build(host: host, container: summary())

        #expect(prompt.contains("`ssh -p 1022 andrew@nettop.local`"))
        #expect(prompt.contains(id.uuidString))
        #expect(prompt.contains("web (id `dbc5c115e83f`)"))
        #expect(prompt.contains("nginx:alpine"))
        #expect(prompt.contains("Compose project: shop, service: web"))
        // Unhealthy (from the status string) selects the health-check task.
        #expect(prompt.contains("health check is failing"))
    }

    @Test func localHostPromptMentionsLocalDaemonAndDefaultPortOmitsFlag() {
        let host = DockerHost(name: "Local", kind: .local)
        let prompt = ContainerPrompt.build(
            host: host,
            container: summary(status: "Up 2 hours")
        )
        #expect(prompt.contains("local Docker daemon"))
        #expect(!prompt.contains("ssh -p"))
        // Healthy running container falls back to the open-question task.
        #expect(prompt.contains("<describe your question here>"))
    }

    @Test func exitedContainerSelectsStoppedTask() {
        let host = DockerHost(name: "Local", kind: .local)
        let prompt = ContainerPrompt.build(
            host: host,
            container: summary(state: "exited", status: "Exited (1) 5 minutes ago")
        )
        #expect(prompt.contains("It is not running"))
    }

    @Test func restartingContainerSelectsCrashLoopTask() {
        let host = DockerHost(name: "Local", kind: .local)
        let prompt = ContainerPrompt.build(
            host: host,
            container: summary(state: "restarting", status: "Restarting (1) 3 seconds ago")
        )
        #expect(prompt.contains("restart loop"))
    }
}

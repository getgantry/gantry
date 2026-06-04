import Testing
@testable import DockerKit

@Test func requestDefaults() {
    let request = DockerRequest(path: "/containers/json")
    #expect(request.method == .get)
    #expect(request.query.isEmpty)
    #expect(request.body == nil)
}

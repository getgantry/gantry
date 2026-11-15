import Testing
@testable import SSHKit

@Suite("SSH command quoting")
struct SSHCommandTests {
    @Test func plainArgumentsStayAsTheyAre() {
        #expect(SSHCommand.quote("buildx") == "buildx")
        #expect(SSHCommand.quote("--format") == "--format")
        #expect(SSHCommand.quote("o4kn3a8tluispaxrrvdsh5ypt") == "o4kn3a8tluispaxrrvdsh5ypt")
    }

    @Test func otherArgumentsGetSingleQuotes() {
        #expect(SSHCommand.quote("") == "''")
        #expect(SSHCommand.quote("a b") == "'a b'")
        #expect(SSHCommand.quote("it's") == #"'it'\''s'"#)
        #expect(SSHCommand.quote("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }
}

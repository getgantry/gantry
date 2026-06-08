import Foundation
import Testing
@testable import DockerKit

struct DockerIgnoreTests {
    @Test func excludesExactNamesAndNestedPaths() {
        let ignore = DockerIgnore(patterns: ["node_modules", ".git"])
        #expect(ignore.excludes("node_modules"))
        #expect(ignore.excludes("node_modules/left-pad/index.js"))
        #expect(ignore.excludes(".git/config"))
        #expect(!ignore.excludes("src/index.js"))
        #expect(!ignore.excludes("node_modules_keep/file"))
    }

    @Test func wildcardsMatchWithinComponents() {
        let ignore = DockerIgnore(patterns: ["*.log", "build/*.tmp"])
        #expect(ignore.excludes("server.log"))
        #expect(ignore.excludes("build/out.tmp"))
        // FNM_PATHNAME: `*` does not cross a slash, so a top-level `*.log`
        // pattern does not match a nested path.
        #expect(!ignore.excludes("logs/server.log"))
        #expect(!ignore.excludes("build/nested/out.tmp"))
    }

    @Test func negationReincludes() {
        let ignore = DockerIgnore(patterns: ["*.md", "!README.md"])
        #expect(ignore.excludes("CHANGELOG.md"))
        #expect(!ignore.excludes("README.md"))
    }

    @Test func laterNegationWinsOverEarlierExclude() {
        let ignore = DockerIgnore(patterns: ["secrets", "!secrets/public.txt"])
        #expect(ignore.excludes("secrets/private.txt"))
        #expect(!ignore.excludes("secrets/public.txt"))
    }

    @Test func alwaysIgnoresDockerignoreItself() {
        let ignore = DockerIgnore(patterns: [])
        #expect(ignore.excludes(".dockerignore"))
    }

    @Test func ignoresCommentsAndBlankLines() {
        let ignore = DockerIgnore(patterns: ["# a comment", "", "  ", "dist"])
        #expect(ignore.excludes("dist/app.js"))
        #expect(!ignore.excludes("src/app.js"))
    }

    @Test func normalizesLeadingDotSlashAndSlashes() {
        let ignore = DockerIgnore(patterns: ["./tmp/", "/cache"])
        #expect(ignore.excludes("tmp/x"))
        #expect(ignore.excludes("cache/y"))
    }
}

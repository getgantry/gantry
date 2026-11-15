import Foundation
import Testing
@testable import AppCore

@Suite struct BuildStepParserTests {
    @Test func classicBuilderSteps() {
        var parser = BuildStepParser()
        parser.consume("Step 1/4 : FROM alpine\n ---> 1234\nStep 2/4 : RUN apk add curl\n")
        #expect(parser.step == 2)
        #expect(parser.total == 4)
        #expect(parser.lastLine == "Step 2/4 : RUN apk add curl")
        #expect(parser.progress.items == .init(done: 2, total: 4, unit: .steps))
    }

    @Test func buildKitPlainOutput() {
        var parser = BuildStepParser()
        parser.consume("#1 [internal] load build definition from Dockerfile\n")
        #expect(parser.step == nil)
        #expect(parser.progress.isEmpty)
        parser.consume("#5 [1/3] FROM docker.io/library/alpine:3.20\n#6 [2/3] RUN apk add curl\n")
        #expect(parser.step == 2)
        // BuildKit prints "DONE" lines of an earlier step again.
        parser.consume("#5 [1/3] FROM docker.io/library/alpine:3.20 DONE 0.4s\n")
        #expect(parser.step == 2)
        parser.consume("#9 [stage-1 3/3] COPY --from=build /out /app\n")
        #expect(parser.step == 3)
        #expect(parser.total == 3)
    }

    @Test func newStageResetsTheStep() {
        var parser = BuildStepParser()
        parser.consume("#7 [build 4/4] RUN make\n#8 [stage-1 1/2] FROM alpine\n")
        #expect(parser.step == 1)
        #expect(parser.total == 2)
    }

    @Test func invalidNumbersAreIgnored() {
        #expect(BuildStepParser.parse("Step 0/3 : FROM x") == nil)
        #expect(BuildStepParser.parse("Step 5/3 : FROM x") == nil)
        #expect(BuildStepParser.parse("RUN echo Step 1/2 :") == nil)
    }
}

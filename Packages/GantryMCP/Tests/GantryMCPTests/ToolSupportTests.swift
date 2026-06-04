import Foundation
import Testing
import MCP
@testable import gantry_mcp

@Suite("ToolSupport")
struct ToolSupportTests {

    // MARK: - cap()

    @Test func capLeavesShortStringUntouched() {
        #expect(cap("hello world", bytes: 1024) == "hello world")
    }

    @Test func capLeavesExactLengthUntouched() {
        let s = String(repeating: "a", count: 50)
        #expect(cap(s, bytes: 50) == s)
    }

    @Test func capTruncatesOverBudgetAndAppendsMarker() {
        let s = String(repeating: "a", count: 100)
        let out = cap(s, bytes: 10)
        #expect(out.hasPrefix(String(repeating: "a", count: 10)))
        #expect(out.contains("truncated"))
        #expect(out.contains("exceeded 10 bytes"))
    }

    @Test func capCountsBytesNotCharacters() {
        // Each emoji is 4 UTF-8 bytes. 5 emoji = 20 bytes; cap to 10 bytes.
        let s = String(repeating: "😀", count: 5)
        #expect(Data(s.utf8).count == 20)
        let out = cap(s, bytes: 10)
        #expect(out.contains("truncated"))
    }

    @Test func capOnUTF8BoundaryProducesReplacementButStaysSafe() {
        // Cut a 4-byte emoji mid-sequence: String(decoding:as:) inserts U+FFFD,
        // it must not crash and must still mark truncation.
        let s = "😀😀😀"  // 12 bytes
        let out = cap(s, bytes: 6)  // boundary inside the 2nd emoji
        #expect(out.contains("truncated"))
        // The kept prefix decodes to at least the first emoji.
        #expect(out.hasPrefix("😀"))
    }

    @Test func capZeroBudgetTruncatesEverything() {
        let out = cap("abc", bytes: 0)
        #expect(out.contains("truncated"))
        #expect(out.hasPrefix("\n…[truncated"))
    }

    // MARK: - Arguments

    @Test func argumentsStringPresentAndAbsent() {
        let args = Arguments(["name": .string("nginx"), "n": .int(3)])
        #expect(args.string("name") == "nginx")
        #expect(args.string("missing") == nil)
        // Non-string value yields nil via stringValue.
        #expect(args.string("n") == nil)
    }

    @Test func argumentsRequiredStringThrowsOnMissing() {
        let args = Arguments([:])
        #expect(throws: ToolError.self) { _ = try args.requiredString("container_id") }
    }

    @Test func argumentsRequiredStringThrowsOnEmpty() {
        let args = Arguments(["container_id": .string("")])
        #expect(throws: ToolError.self) { _ = try args.requiredString("container_id") }
    }

    @Test func argumentsRequiredStringReturnsValue() throws {
        let args = Arguments(["container_id": .string("abc")])
        #expect(try args.requiredString("container_id") == "abc")
    }

    @Test func argumentsBoolDefaults() {
        let args = Arguments(["a": .bool(false)])
        #expect(args.bool("a", default: true) == false)
        #expect(args.bool("missing", default: true) == true)
        #expect(args.bool("missing", default: false) == false)
    }

    @Test func argumentsIntFromIntAndDouble() {
        let args = Arguments(["i": .int(7), "d": .double(3.9)])
        #expect(args.int("i", default: 0) == 7)
        // Doubles are truncated toward zero.
        #expect(args.int("d", default: 0) == 3)
        #expect(args.int("missing", default: 42) == 42)
    }

    @Test func argumentsUUIDNilWhenAbsentOrEmpty() throws {
        #expect(try Arguments([:]).uuid("host_id") == nil)
        #expect(try Arguments(["host_id": .string("")]).uuid("host_id") == nil)
    }

    @Test func argumentsUUIDParsesValid() throws {
        let id = UUID()
        let parsed = try Arguments(["host_id": .string(id.uuidString)]).uuid("host_id")
        #expect(parsed == id)
    }

    @Test func argumentsUUIDThrowsOnInvalid() {
        let args = Arguments(["host_id": .string("not-a-uuid")])
        #expect(throws: ToolError.self) { _ = try args.uuid("host_id") }
    }

    @Test func argumentsNilBagIsEmpty() {
        let args = Arguments(nil)
        #expect(args.raw.isEmpty)
    }

    // MARK: - ToolError

    @Test func toolErrorExposesMessageAsDescription() {
        let err = ToolError("boom")
        #expect(err.message == "boom")
        #expect(err.errorDescription == "boom")
    }

    // MARK: - Schema builders

    @Test func schemaObjectWithoutRequired() {
        let schema = Schema.object(properties: ["a": Schema.boolean("x")])
        guard case let .object(obj) = schema else { Issue.record("not object"); return }
        #expect(obj["type"]?.stringValue == "object")
        #expect(obj["properties"] != nil)
        #expect(obj["required"] == nil)
    }

    @Test func schemaObjectWithRequired() {
        let schema = Schema.object(properties: ["a": Schema.string("x")], required: ["a"])
        guard case let .object(obj) = schema, case let .array(req)? = obj["required"] else {
            Issue.record("missing required")
            return
        }
        #expect(req.first?.stringValue == "a")
    }

    @Test func schemaStringWithEnum() {
        let schema = Schema.string("desc", enumValues: ["start", "stop"])
        guard case let .object(obj) = schema, case let .array(values)? = obj["enum"] else {
            Issue.record("missing enum")
            return
        }
        #expect(values.map(\.stringValue) == ["start", "stop"])
        #expect(obj["type"]?.stringValue == "string")
        #expect(obj["description"]?.stringValue == "desc")
    }

    @Test func schemaStringWithoutEnum() {
        let schema = Schema.string("desc")
        guard case let .object(obj) = schema else { Issue.record("not object"); return }
        #expect(obj["enum"] == nil)
    }

    @Test func schemaIntegerAndBoolean() {
        guard case let .object(i) = Schema.integer("n") else { Issue.record("int"); return }
        #expect(i["type"]?.stringValue == "integer")
        guard case let .object(b) = Schema.boolean("flag") else { Issue.record("bool"); return }
        #expect(b["type"]?.stringValue == "boolean")
    }

    // MARK: - Result helpers

    @Test func textResultIsNotError() {
        let r = CallTool.Result.text("hi")
        #expect(r.isError == false)
        #expect(r.text == "hi")
    }

    @Test func failureResultIsError() {
        let r = CallTool.Result.failure("nope")
        #expect(r.isError == true)
        #expect(r.text == "nope")
    }

    // MARK: - jsonText

    @Test func jsonTextEncodesSortedKeysWithoutEscapingSlashes() throws {
        struct Pair: Encodable { var b: String; var a: String }
        let out = try jsonText(Pair(b: "x/y", a: "1"))
        // sortedKeys => "a" before "b"; slashes not escaped.
        #expect(out.contains("\"a\""))
        #expect(out.range(of: "\"a\"")!.lowerBound < out.range(of: "\"b\"")!.lowerBound)
        #expect(out.contains("x/y"))
        #expect(!out.contains("x\\/y"))
        // pretty printed => has newlines.
        #expect(out.contains("\n"))
    }
}

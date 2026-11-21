import Testing
import Foundation
import DockerKit
@testable import SSHKit

@Suite("Stream head")
struct StreamHeadTests {
    /// A small chunked response (a tar of a tiny volume) in one chunk.
    @Test func wholeResponseInTheFirstChunkEnds() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n0\r\n\r\n"
        var parser = HTTP1ResponseParser()
        var start = StreamHead()
        #expect(start.consume(try parser.ingest(Data(raw.utf8))))
        #expect(start.head?.status == 200)
        #expect(start.ended)
        #expect(start.bodies.reduce(Data(), +) == Data("hello".utf8))
    }

    @Test func headOnlyKeepsStreaming() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"
        var parser = HTTP1ResponseParser()
        var start = StreamHead()
        #expect(start.consume(try parser.ingest(Data(raw.utf8))))
        #expect(!start.ended)
    }

    @Test func partialHeadAsksForMore() throws {
        var parser = HTTP1ResponseParser()
        var start = StreamHead()
        #expect(!start.consume(try parser.ingest(Data("HTTP/1.1 200 OK\r\nTransfer-".utf8))))
        #expect(start.head == nil)
    }
}

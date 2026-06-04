import Foundation
import Testing
@testable import DockerKit

// MARK: - Helpers

/// Feeds a parser the given bytes one byte at a time, collecting all events.
private func ingestByteByByte(_ parser: inout HTTP1ResponseParser, _ data: Data) throws -> [HTTP1ResponseParser.Event] {
    var events: [HTTP1ResponseParser.Event] = []
    for byte in data {
        events.append(contentsOf: try parser.ingest(Data([byte])))
    }
    return events
}

private func bodyData(_ events: [HTTP1ResponseParser.Event]) -> Data {
    var out = Data()
    for case .body(let chunk) in events {
        out.append(chunk)
    }
    return out
}

private func headEvent(_ events: [HTTP1ResponseParser.Event]) -> (Int, [String: String])? {
    for case .head(let status, let headers) in events {
        return (status, headers)
    }
    return nil
}

private func endCount(_ events: [HTTP1ResponseParser.Event]) -> Int {
    events.reduce(0) { count, event in
        if case .end = event { return count + 1 }
        return count
    }
}

// MARK: - Status + headers split across boundaries

@Test func parserStatusAndHeadersSplitAcrossOddBoundaries() throws {
    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Custom: value\r\nContent-Length: 0\r\n\r\n"
    var parser = HTTP1ResponseParser()
    let events = try ingestByteByByte(&parser, Data(response.utf8))

    let head = try #require(headEvent(events))
    #expect(head.0 == 200)
    #expect(head.1["content-type"] == "application/json")
    #expect(head.1["x-custom"] == "value")
    #expect(head.1["content-length"] == "0")
    #expect(endCount(events) == 1)
}

@Test func parserStatusLineWithoutReasonPhrase() throws {
    let response = "HTTP/1.1 204\r\n\r\n"
    var parser = HTTP1ResponseParser()
    let events = try parser.ingest(Data(response.utf8))
    let head = try #require(headEvent(events))
    #expect(head.0 == 204)
    #expect(endCount(events) == 1)
}

// MARK: - Content-Length body in 1-byte chunks

@Test func parserContentLengthBodyInSingleByteChunks() throws {
    let body = "{\"ok\":true}"
    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    var parser = HTTP1ResponseParser()
    let events = try ingestByteByByte(&parser, Data(response.utf8))

    let head = try #require(headEvent(events))
    #expect(head.0 == 200)
    #expect(bodyData(events) == Data(body.utf8))
    #expect(endCount(events) == 1)
}

@Test func parserContentLengthBodyAllAtOnce() throws {
    let body = "hello"
    let response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n\(body)"
    var parser = HTTP1ResponseParser()
    let events = try parser.ingest(Data(response.utf8))
    #expect(bodyData(events) == Data(body.utf8))
    #expect(endCount(events) == 1)
}

// MARK: - Chunked decoding

@Test func parserChunkedMultiChunkWithExtensionsAndTrailers() throws {
    // Two data chunks; one with a chunk extension; a trailer header at the end.
    var raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    raw += "4\r\nWiki\r\n"
    raw += "5;name=value\r\npedia\r\n"
    raw += "0\r\nX-Trailer: done\r\n\r\n"

    var parser = HTTP1ResponseParser()
    let events = try parser.ingest(Data(raw.utf8))
    let head = try #require(headEvent(events))
    #expect(head.0 == 200)
    #expect(bodyData(events) == Data("Wikipedia".utf8))
    #expect(endCount(events) == 1)
}

@Test func parserChunkedSplitAcrossBoundaries() throws {
    var raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    raw += "3\r\nabc\r\n"
    raw += "1a\r\nabcdefghijklmnopqrstuvwxyz\r\n"
    raw += "0\r\n\r\n"

    var parser = HTTP1ResponseParser()
    let events = try ingestByteByByte(&parser, Data(raw.utf8))
    #expect(bodyData(events) == Data("abcabcdefghijklmnopqrstuvwxyz".utf8))
    #expect(endCount(events) == 1)
}

@Test func parserRejectsMalformedChunkSize() throws {
    var raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    raw += "zz\r\n"
    var parser = HTTP1ResponseParser()
    #expect(throws: HTTP1ParseError.self) {
        _ = try parser.ingest(Data(raw.utf8))
    }
}

// MARK: - Keep-alive: 204 then immediate next response

@Test func parser204ThenNextResponseInSameBufferResets() throws {
    let body = "second"
    var raw = "HTTP/1.1 204 No Content\r\n\r\n"
    raw += "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"

    var parser = HTTP1ResponseParser()
    let events = try parser.ingest(Data(raw.utf8))

    // Expect: head(204), end, head(200), body(second), end.
    var heads: [Int] = []
    for case .head(let status, _) in events { heads.append(status) }
    #expect(heads == [204, 200])
    #expect(bodyData(events) == Data(body.utf8))
    #expect(endCount(events) == 2)
}

@Test func parserContentLengthThenNextResponseResets() throws {
    var raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
    raw += "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nbye"
    var parser = HTTP1ResponseParser()
    let events = try parser.ingest(Data(raw.utf8))
    #expect(bodyData(events) == Data("hibye".utf8))
    #expect(endCount(events) == 2)
}

// MARK: - 101 passthrough

@Test func parser101PassthroughNeverEnds() throws {
    var parser = HTTP1ResponseParser()
    let headBytes = "HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp\r\nConnection: Upgrade\r\n\r\n"
    var events = try parser.ingest(Data(headBytes.utf8))
    let head = try #require(headEvent(events))
    #expect(head.0 == 101)
    #expect(endCount(events) == 0)

    // Arbitrary raw bytes that resemble another HTTP response are still body.
    events = try parser.ingest(Data("HTTP/1.1 200 OK\r\n\r\nraw".utf8))
    #expect(endCount(events) == 0)
    events += try parser.ingest(Data([0x00, 0x01, 0xFF]))
    #expect(endCount(events) == 0)

    // finish() does not emit .end for passthrough.
    let final = try parser.finish()
    #expect(endCount(final) == 0)
}

// MARK: - Read-until-close

@Test func parserReadUntilCloseEndsOnFinish() throws {
    var parser = HTTP1ResponseParser()
    var events = try parser.ingest(Data("HTTP/1.1 200 OK\r\nServer: x\r\n\r\n".utf8))
    let head = try #require(headEvent(events))
    #expect(head.0 == 200)
    #expect(endCount(events) == 0)

    events += try parser.ingest(Data("chunk-one".utf8))
    events += try parser.ingest(Data("chunk-two".utf8))
    #expect(endCount(events) == 0)

    let final = try parser.finish()
    events += final
    #expect(bodyData(events) == Data("chunk-onechunk-two".utf8))
    #expect(endCount(final) == 1)
}

@Test func parserFinishMidHeadersThrows() throws {
    var parser = HTTP1ResponseParser()
    _ = try parser.ingest(Data("HTTP/1.1 200 OK\r\nContent-Len".utf8))
    #expect(throws: HTTP1ParseError.self) {
        _ = try parser.finish()
    }
}

@Test func parserFinishOnIdleConnectionIsClean() throws {
    var parser = HTTP1ResponseParser()
    let events = try parser.finish()
    #expect(events.isEmpty)
}

@Test func parserRejectsMalformedStatusLine() throws {
    var parser = HTTP1ResponseParser()
    #expect(throws: HTTP1ParseError.self) {
        _ = try parser.ingest(Data("NOT-HTTP garbage\r\n".utf8))
    }
}

// MARK: - Serializer golden bytes

@Test func serializerGetNoBody() {
    let request = DockerRequest(
        method: .get,
        path: "/v1.47/containers/json",
        query: [URLQueryItem(name: "all", value: "true")]
    )
    let data = HTTP1RequestSerializer.serialize(request)
    let text = String(data: data, encoding: .utf8)!
    let expected = "GET /v1.47/containers/json?all=true HTTP/1.1\r\nHost: docker\r\nConnection: keep-alive\r\n\r\n"
    #expect(text == expected)
}

@Test func serializerPostJsonWithBody() {
    let body = Data("{\"Image\":\"nginx\"}".utf8)
    let request = DockerRequest(
        method: .post,
        path: "/v1.47/containers/create",
        body: body
    )
    let data = HTTP1RequestSerializer.serialize(request)
    let text = String(data: data, encoding: .utf8)!
    let expected =
        "POST /v1.47/containers/create HTTP/1.1\r\n" +
        "Host: docker\r\n" +
        "Connection: keep-alive\r\n" +
        "Content-Length: \(body.count)\r\n" +
        "Content-Type: application/json\r\n" +
        "\r\n" +
        "{\"Image\":\"nginx\"}"
    #expect(text == expected)
}

@Test func serializerPostNoBodyGetsZeroContentLength() {
    let request = DockerRequest(method: .post, path: "/v1.47/containers/abc/start")
    let data = HTTP1RequestSerializer.serialize(request)
    let text = String(data: data, encoding: .utf8)!
    let expected =
        "POST /v1.47/containers/abc/start HTTP/1.1\r\n" +
        "Host: docker\r\n" +
        "Connection: keep-alive\r\n" +
        "Content-Length: 0\r\n" +
        "\r\n"
    #expect(text == expected)
}

@Test func serializerRespectsCallerContentType() {
    let body = Data("rawbytes".utf8)
    let request = DockerRequest(
        method: .put,
        path: "/v1.47/containers/abc/archive",
        headers: ["Content-Type": "application/x-tar"],
        body: body
    )
    let data = HTTP1RequestSerializer.serialize(request)
    let text = String(data: data, encoding: .utf8)!
    #expect(text.contains("Content-Type: application/x-tar\r\n"))
    #expect(!text.contains("application/json"))
    #expect(text.contains("Content-Length: \(body.count)\r\n"))
}

@Test func serializerRoundTripsThroughParser() throws {
    // A serialized request is not a response, but we can validate that the
    // parser handles a body produced with the same length accounting by
    // crafting a matching response.
    let body = Data("{\"x\":1}".utf8)
    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".data(using: .utf8)! + body
    var parser = HTTP1ResponseParser()
    let events = try parser.ingest(response)
    #expect(bodyData(events) == body)
    #expect(endCount(events) == 1)
}

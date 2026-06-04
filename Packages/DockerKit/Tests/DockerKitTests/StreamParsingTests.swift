import Foundation
import Testing
@testable import DockerKit

// MARK: - Helpers

/// Builds one Docker multiplexed log frame.
private func frame(_ stream: LogStreamType, _ payload: String) -> Data {
    let body = Data(payload.utf8)
    var data = Data([stream.rawValue, 0, 0, 0])
    let size = UInt32(body.count)
    data.append(UInt8((size >> 24) & 0xFF))
    data.append(UInt8((size >> 16) & 0xFF))
    data.append(UInt8((size >> 8) & 0xFF))
    data.append(UInt8(size & 0xFF))
    data.append(body)
    return data
}

// MARK: - Demuxer

@Test func demuxerSingleFrameSingleLine() {
    var demuxer = DockerLogDemuxer()
    let entries = demuxer.ingest(frame(.stdout, "hello world\n"))
    #expect(entries.count == 1)
    #expect(entries[0].text == "hello world")
    #expect(entries[0].stream == .stdout)
    #expect(entries[0].id == 0)
}

@Test func demuxerMultipleFramesInOneChunk() {
    var demuxer = DockerLogDemuxer()
    var chunk = frame(.stdout, "line1\n")
    chunk.append(frame(.stderr, "err1\n"))
    chunk.append(frame(.stdout, "line2\n"))
    let entries = demuxer.ingest(chunk)
    #expect(entries.count == 3)
    #expect(entries[0].text == "line1")
    #expect(entries[0].stream == .stdout)
    #expect(entries[1].text == "err1")
    #expect(entries[1].stream == .stderr)
    #expect(entries[2].text == "line2")
    // Sequence is monotonic across streams.
    #expect(entries.map(\.id) == [0, 1, 2])
}

@Test func demuxerHeaderSplitAcrossChunks() {
    var demuxer = DockerLogDemuxer()
    let full = frame(.stdout, "split header\n")
    // Split in the middle of the 8-byte header.
    let first = full.prefix(3)
    let rest = full.suffix(from: full.index(full.startIndex, offsetBy: 3))

    #expect(demuxer.ingest(Data(first)).isEmpty)
    let entries = demuxer.ingest(Data(rest))
    #expect(entries.count == 1)
    #expect(entries[0].text == "split header")
}

@Test func demuxerPayloadSplitAcrossChunks() {
    var demuxer = DockerLogDemuxer()
    let full = frame(.stdout, "a long payload line\n")
    // Split inside the payload (header is 8 bytes; cut at 12).
    let first = full.prefix(12)
    let rest = full.suffix(from: full.index(full.startIndex, offsetBy: 12))

    #expect(demuxer.ingest(Data(first)).isEmpty)
    let entries = demuxer.ingest(Data(rest))
    #expect(entries.count == 1)
    #expect(entries[0].text == "a long payload line")
}

@Test func demuxerLineBufferedAcrossFrames() {
    var demuxer = DockerLogDemuxer()
    // A logical line "hello world" delivered as two frames without a newline
    // until the second frame.
    let entries1 = demuxer.ingest(frame(.stdout, "hello "))
    #expect(entries1.isEmpty)
    let entries2 = demuxer.ingest(frame(.stdout, "world\n"))
    #expect(entries2.count == 1)
    #expect(entries2[0].text == "hello world")
}

@Test func demuxerSeparatesPartialLinesPerStream() {
    var demuxer = DockerLogDemuxer()
    _ = demuxer.ingest(frame(.stdout, "out-part "))
    _ = demuxer.ingest(frame(.stderr, "err-part "))
    let entries = demuxer.ingest(frame(.stdout, "done\n"))
    #expect(entries.count == 1)
    #expect(entries[0].text == "out-part done")
    #expect(entries[0].stream == .stdout)

    let finished = demuxer.finish()
    #expect(finished.count == 1)
    #expect(finished[0].text == "err-part ")
    #expect(finished[0].stream == .stderr)
}

@Test func demuxerStripsCarriageReturn() {
    var demuxer = DockerLogDemuxer()
    let entries = demuxer.ingest(frame(.stdout, "with cr\r\n"))
    #expect(entries.count == 1)
    #expect(entries[0].text == "with cr")
}

@Test func demuxerFinishFlushesRemainder() {
    var demuxer = DockerLogDemuxer()
    _ = demuxer.ingest(frame(.stdout, "no newline here"))
    let finished = demuxer.finish()
    #expect(finished.count == 1)
    #expect(finished[0].text == "no newline here")
}

@Test func demuxerParsesTimestamps() {
    var demuxer = DockerLogDemuxer(parseTimestamps: true)
    let entries = demuxer.ingest(frame(.stdout, "2024-01-15T10:30:00.123456789Z application started\n"))
    #expect(entries.count == 1)
    #expect(entries[0].text == "application started")
    #expect(entries[0].timestamp != nil)
}

// MARK: - Raw TTY parser

@Test func rawParserSplitsLines() {
    var parser = RawLogLineParser()
    let entries = parser.ingest(Data("line one\nline two\n".utf8))
    #expect(entries.count == 2)
    #expect(entries[0].text == "line one")
    #expect(entries[1].text == "line two")
    #expect(entries.allSatisfy { $0.stream == .stdout })
}

@Test func rawParserBuffersPartialLinesAcrossChunks() {
    var parser = RawLogLineParser()
    #expect(parser.ingest(Data("partial ".utf8)).isEmpty)
    let entries = parser.ingest(Data("complete\n".utf8))
    #expect(entries.count == 1)
    #expect(entries[0].text == "partial complete")
}

@Test func rawParserFinishFlushesRemainder() {
    var parser = RawLogLineParser()
    _ = parser.ingest(Data("tail".utf8))
    let finished = parser.finish()
    #expect(finished.count == 1)
    #expect(finished[0].text == "tail")
}

// MARK: - JSONLinesDecoder

private struct Probe: Decodable, Sendable, Equatable {
    var value: Int
}

@Test func jsonLinesDecodesCompleteLines() {
    var decoder = JSONLinesDecoder<Probe>()
    let results = decoder.ingest(Data("{\"value\":1}\n{\"value\":2}\n".utf8))
    #expect(results == [Probe(value: 1), Probe(value: 2)])
}

@Test func jsonLinesBuffersPartialLine() {
    var decoder = JSONLinesDecoder<Probe>()
    let first = decoder.ingest(Data("{\"value\":".utf8))
    #expect(first.isEmpty)
    let second = decoder.ingest(Data("42}\n".utf8))
    #expect(second == [Probe(value: 42)])
}

@Test func jsonLinesSkipsUndecodableLines() {
    var decoder = JSONLinesDecoder<Probe>()
    // Empty line and garbage line are skipped, valid line decoded.
    let results = decoder.ingest(Data("\n{\"value\":7}\nnot json\n\n".utf8))
    #expect(results == [Probe(value: 7)])
}

// MARK: - Stats decode

@Test func statsSampleDecodesFromFixture() throws {
    // Representative cgroup v2 sample with a non-empty precpu so CPU% > 0.
    let json = """
    {
      "read": "2024-01-15T10:30:00.123456789Z",
      "cpu_stats": {
        "cpu_usage": { "total_usage": 200000000 },
        "system_cpu_usage": 2000000000,
        "online_cpus": 4
      },
      "precpu_stats": {
        "cpu_usage": { "total_usage": 100000000 },
        "system_cpu_usage": 1000000000,
        "online_cpus": 4
      },
      "memory_stats": {
        "usage": 104857600,
        "limit": 2097152000,
        "stats": { "inactive_file": 4857600, "total_inactive_file": 4857600 }
      },
      "networks": {
        "eth0": { "rx_bytes": 1000, "tx_bytes": 2000 },
        "eth1": { "rx_bytes": 500, "tx_bytes": 250 }
      },
      "blkio_stats": {
        "io_service_bytes_recursive": [
          { "op": "read", "value": 8192 },
          { "op": "write", "value": 4096 },
          { "op": "Read", "value": 1000 }
        ]
      },
      "pids_stats": { "current": 12 }
    }
    """
    let sample = try JSONDecoder().decode(ContainerStatsSample.self, from: Data(json.utf8))

    #expect(sample.onlineCPUs == 4)
    // cpuDelta = 100000000, sysDelta = 1000000000 -> 0.1 * 4 * 100 = 40%
    #expect(abs(sample.cpuPercent - 40.0) < 0.0001)
    // used = 104857600 - 4857600 = 100000000
    #expect(sample.memoryUsageBytes == 100_000_000)
    #expect(sample.memoryLimitBytes == 2_097_152_000)
    #expect(sample.memoryPercent > 4 && sample.memoryPercent < 5)
    #expect(sample.networkRxBytes == 1500)
    #expect(sample.networkTxBytes == 2250)
    // read + Read summed case-insensitively = 8192 + 1000 = 9192
    #expect(sample.blockReadBytes == 9192)
    #expect(sample.blockWriteBytes == 4096)
    #expect(sample.pids == 12)
}

@Test func statsSampleFirstSampleHasZeroCPU() throws {
    // First streamed sample: precpu equals cpu_stats, so deltas are zero and
    // CPU% must be 0. Memory limit 0 -> memoryPercent 0.
    let json = """
    {
      "read": "2024-01-15T10:30:00Z",
      "cpu_stats": {
        "cpu_usage": { "total_usage": 200000000 },
        "system_cpu_usage": 2000000000,
        "online_cpus": 2
      },
      "precpu_stats": {
        "cpu_usage": { "total_usage": 200000000 },
        "system_cpu_usage": 2000000000,
        "online_cpus": 2
      },
      "memory_stats": { "usage": 1000, "limit": 0 },
      "pids_stats": { "current": 1 }
    }
    """
    let sample = try JSONDecoder().decode(ContainerStatsSample.self, from: Data(json.utf8))
    #expect(sample.cpuPercent == 0)
    // limit 0 -> memoryPercent 0
    #expect(sample.memoryPercent == 0)
    #expect(sample.networkRxBytes == 0)
    #expect(sample.blockReadBytes == 0)
}

// MARK: - Event decode

@Test func dockerEventDecodes() throws {
    let json = """
    {
      "Type": "container",
      "Action": "start",
      "Actor": {
        "ID": "abc123",
        "Attributes": { "name": "my-app", "image": "nginx" }
      },
      "time": 1705315800,
      "timeNano": 1705315800123456789
    }
    """
    let event = try JSONDecoder().decode(DockerEvent.self, from: Data(json.utf8))
    #expect(event.type == "container")
    #expect(event.action == "start")
    #expect(event.actorID == "abc123")
    #expect(event.isContainerEvent)
    #expect(event.containerName == "my-app")
    #expect(event.time == 1705315800)
    #expect(event.timeNano == 1705315800123456789)
}

@Test func dockerEventDefaultsWhenMissingActor() throws {
    let json = """
    { "Type": "network", "Action": "connect" }
    """
    let event = try JSONDecoder().decode(DockerEvent.self, from: Data(json.utf8))
    #expect(event.type == "network")
    #expect(event.actorID.isEmpty)
    #expect(event.actorAttributes.isEmpty)
    #expect(event.containerName == nil)
    #expect(!event.isContainerEvent)
}

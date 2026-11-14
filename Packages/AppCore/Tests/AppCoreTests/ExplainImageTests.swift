import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import AppCore

/// Images made in memory, so the tests need no files.
enum TestImages {
    struct EncodeError: Error {}

    static func cgImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EncodeError() }
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw EncodeError() }
        return image
    }

    /// PNG (or JPEG with an EXIF orientation) data of a plain image.
    static func data(width: Int, height: Int, type: UTType = .png, orientation: Int? = nil) throws -> Data {
        let image = try cgImage(width: width, height: height)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw EncodeError()
        }
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError() }
        return data as Data
    }

    static func explainImage(width: Int, height: Int) throws -> ExplainImage {
        ExplainImage(name: "test.png", cgImage: try cgImage(width: width, height: height))
    }
}

@Suite struct ExplainImagePreparerTests {
    @Test func downscalesTheLongerSideTo1024() throws {
        let image = try ExplainImagePreparer.prepare(data: TestImages.data(width: 4000, height: 3000), name: "big.png")
        #expect(image.width == 1024)
        #expect(image.height == 768)
        #expect(image.name == "big.png")
    }

    @Test func keepsASmallImageAtItsSize() throws {
        let image = try ExplainImagePreparer.prepare(data: TestImages.data(width: 300, height: 200), name: "small.png")
        #expect(image.width == 300)
        #expect(image.height == 200)
    }

    @Test func appliesTheOrientation() throws {
        // EXIF 6: the stored pixels are landscape, the picture is portrait.
        let data = try TestImages.data(width: 2000, height: 1000, type: .jpeg, orientation: 6)
        let image = try ExplainImagePreparer.prepare(data: data, name: "phone.jpg")
        #expect(image.width == 512)
        #expect(image.height == 1024)
    }

    @Test func refusesDataThatIsNotAnImage() {
        #expect(throws: ExplainImageRejection.notAnImage) {
            try ExplainImagePreparer.prepare(data: Data("hello, not a picture".utf8), name: "notes.txt")
        }
    }

    @Test func refusesTooLargeData() {
        let data = Data(count: ExplainImageLimits.maxBytes + 1)
        #expect(throws: ExplainImageRejection.tooLarge(limitMB: 20)) {
            try ExplainImagePreparer.prepare(data: data, name: "huge.png")
        }
    }

    @Test func refusesATooLargeFileBeforeReadingIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gei-\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ExplainImageLimits.maxBytes + 1))
        try handle.close()
        #expect(throws: ExplainImageRejection.tooLarge(limitMB: 20)) {
            try ExplainImagePreparer.prepare(.file(url))
        }
    }

    @Test func addingStopsAtTheLimitAndKeepsTheFirstRejection() throws {
        let png = try TestImages.data(width: 40, height: 40)
        let existing = [try TestImages.explainImage(width: 10, height: 10)]
        let sources: [ExplainImageSource] = [
            .data(Data("text".utf8), name: "a.txt"),
            .data(png, name: "b.png"),
            .data(png, name: "c.png"),
            .data(png, name: "d.png")
        ]
        let result = ExplainImagePreparer.adding(sources, to: existing)
        #expect(result.images.count == ExplainImageLimits.maxCount)
        #expect(result.images.first == existing.first)
        #expect(result.images.map(\.name).suffix(2) == ["b.png", "c.png"])
        #expect(result.rejection == .notAnImage)
    }

    @Test func addingToAFullListIsRefused() throws {
        let full = try (0..<3).map { _ in try TestImages.explainImage(width: 8, height: 8) }
        let result = ExplainImagePreparer.adding([.data(try TestImages.data(width: 8, height: 8), name: "x.png")], to: full)
        #expect(result.images == full)
        #expect(result.rejection == .tooMany(limit: 3))
    }

    @Test func rejectionTextsNameTheLimits() {
        #expect(ExplainImageRejection.tooMany(limit: 3).message.contains("3"))
        #expect(ExplainImageRejection.tooLarge(limitMB: 20).message.contains("20"))
        #expect(!ExplainImageRejection.notAnImage.message.isEmpty)
    }
}

@MainActor
@Suite struct ExplainControllerImageTests {
    private struct Explainer: FailureExplaining {
        let log: ImageLog
        func explain(_ context: FailureContext, data: ExplainDataSource, images: [ExplainImage]) async throws -> FailureExplanation {
            log.record(images.count)
            return FailureExplanation(cause: "c", evidence: [], confidence: .low, steps: [])
        }
    }

    private func controller(
        _ availability: ExplainAvailability,
        imageSupport: Bool,
        explained: ImageLog,
        gathered: ImageLog
    ) -> ExplainController {
        ExplainController(
            availability: { availability },
            makeExplainer: { _ in Explainer(log: explained) },
            gather: { _, images in
                gathered.record(images.count)
                return (FailureContext(subject: .container, title: "x", hostName: "h", engine: "apple/container"),
                        ExplainDataSource(logs: { _ in [] }))
            },
            imageSupport: { _ in imageSupport }
        )
    }

    @Test func addedImagesGoToTheModelAndRestartTheAnalysis() async throws {
        let explained = ImageLog(), gathered = ImageLog()
        let c = controller(.available(.onDevice), imageSupport: true, explained: explained, gathered: gathered)
        c.start()
        await c.wait()
        #expect(c.supportsImages)

        let png = try TestImages.data(width: 100, height: 50)
        await c.addImages([.data(png, name: "one.png"), .data(png, name: "two.png")])
        await c.wait()
        #expect(c.images.count == 2)
        #expect(explained.all == [0, 2])
        #expect(gathered.all == [0, 2])

        c.removeImage(id: c.images[0].id)
        await c.wait()
        #expect(c.images.map(\.name) == ["two.png"])
        #expect(explained.all == [0, 2, 1])
    }

    @Test func fourthImageIsRefusedAndNothingReruns() async throws {
        let explained = ImageLog()
        let c = controller(.available(.onDevice), imageSupport: true, explained: explained, gathered: ImageLog())
        c.start()
        await c.wait()
        let png = try TestImages.data(width: 20, height: 20)
        await c.addImages((1...3).map { .data(png, name: "\($0).png") })
        await c.wait()
        await c.addImages([.data(png, name: "4.png")])
        await c.wait()
        #expect(c.images.count == 3)
        #expect(c.lastRejection == .tooMany(limit: 3))
        #expect(explained.all == [0, 3])
    }

    @Test func privateCloudGetsNoImagesEvenIfTheGateSaysYes() async throws {
        let explained = ImageLog()
        let c = controller(.available(.privateCloud), imageSupport: true, explained: explained, gathered: ImageLog())
        c.start()
        await c.wait()
        #expect(!c.supportsImages)
        await c.addImages([.data(try TestImages.data(width: 20, height: 20), name: "a.png")])
        await c.wait()
        #expect(c.images.isEmpty)
        #expect(explained.all == [0])
    }

    @Test func noVisionMeansNoAttachments() async throws {
        let c = controller(.available(.onDevice), imageSupport: false, explained: ImageLog(), gathered: ImageLog())
        c.start()
        await c.wait()
        #expect(!c.supportsImages)
        await c.addImages([.data(try TestImages.data(width: 20, height: 20), name: "a.png")])
        #expect(c.images.isEmpty)
    }

    @Test func unavailableModelHidesAttachments() async {
        let c = controller(.unavailable(.appleIntelligenceNotEnabled), imageSupport: true, explained: ImageLog(), gathered: ImageLog())
        c.start()
        #expect(!c.supportsImages)
    }
}

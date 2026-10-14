import AppKit
import CryptoKit
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import Vision
import TravelCore
import TravelStorage
@testable import TravelUI

@MainActor
final class PostcardScenicFaceTests: XCTestCase {
    func testFramedSceneryExportHasPaperMarginAndPreservesSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("postcards/sample"), withIntermediateDirectories: true)
        let original = try sourcePhoto()
        try original.write(to: root.appendingPathComponent("postcards/sample/photo.png"))
        let data = try await PostcardExporter.pngData(event: event(place: "西湖湖边"), rootURL: root)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let corner = try pixel(image, x: 12, y: 12)
        XCTAssertGreaterThan(corner.red, 0.9, "A framed photograph needs a warm paper margin")
        XCTAssertGreaterThan(corner.green, 0.85)
        XCTAssertGreaterThan(corner.red - corner.blue, 0.015)
        XCTAssertEqual(image.width, 1536)
        XCTAssertEqual(image.height, 1024)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("postcards/sample/photo.png")), original)
    }

    func testHeritageExportHasThinPaperBorderAndMountainKeepsFullBleed() async throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try decode(await PostcardExporter.pngData(event: event(place: "故宫古迹"), rootURL: root))
        let fullBleed = try decode(await PostcardExporter.pngData(event: event(place: "雪山徒步"), rootURL: root))
        let journalPaper = try pixel(journal, x: 1470, y: 512)
        let journalPhoto = try pixel(journal, x: 1350, y: 512)
        let mountainCorner = try pixel(fullBleed, x: 12, y: 12)
        XCTAssertGreaterThan(journalPaper.red, 0.9, "The heritage card retains its paper edge")
        XCTAssertGreaterThan(journalPhoto.blue - journalPhoto.red, 0.2, "The photograph replaces the former quote column")
        XCTAssertGreaterThan(mountainCorner.blue - mountainCorner.red, 0.2, "Mountain photograph should reach the edge")
        XCTAssertEqual(journal.width, fullBleed.width)
        XCTAssertEqual(journal.height, fullBleed.height)
    }

    func testExportAcceptsLegalTwentyFourMegapixelPhotoAndPreservesSource() async throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try sourcePhoto(width: 6000, height: 4000)
        let sourceURL = root.appendingPathComponent("postcards/sample/photo.png")
        try original.write(to: sourceURL)
        let uiPhoto = try PostcardImageDecoder.decodeThumbnail(data: original)
        XCTAssertEqual(max(uiPhoto.width, uiPhoto.height), PostcardImageDecoder.maximumPixelSize)
        let output = try decode(await PostcardExporter.pngData(event: event(place: "西湖湖边"), rootURL: root))
        XCTAssertEqual(output.width, 1536)
        XCTAssertEqual(output.height, 1024)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    func testExportRotationMatchesNormalizedUIPhotoAndPreservesSource() async throws {
        try await assertOrientedExportMatchesUI(orientation: 6)
    }

    func testExportMirrorMatchesNormalizedUIPhotoAndPreservesSource() async throws {
        try await assertOrientedExportMatchesUI(orientation: 2)
    }

    func testBorderedPortraitRetainsAllFourPhotoCornersAndQuoteInsidePhoto() async throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try orientedPhoto(orientation: 6, edgeMarkers: true)
        let sourceURL = root.appendingPathComponent("postcards/sample/photo.png")
        try source.write(to: sourceURL)
        let photo = try PostcardImageDecoder.decodeThumbnail(data: source)
        for place in ["西湖湖边", "故宫古迹"] {
            let output = try decode(await PostcardExporter.pngData(event: event(place: place), rootURL: root))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.customWords = ["风景正好"]
            try VNImageRequestHandler(cgImage: output).perform([request])
            let observations = request.results ?? []
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
            XCTAssertTrue(text.contains("风景正好"), "The portrait quote must remain fully readable: \(text)")
            try png(output).write(to: URL(fileURLWithPath: "/tmp/travelcat-quote-inside-portrait-\(place == "西湖湖边" ? "paperBorder" : "journal").png"))
            let inset = place == "西湖湖边" ? 0.035 : 0.055
            let photoHeight = 1024 * (1 - inset * 2)
            let photoWidth = photoHeight * 2 / 3
            let photoRect = CGRect(x: (1536 - photoWidth) / 2, y: 1024 * inset,
                width: photoWidth, height: photoHeight)
            let normalized = CGRect(x: photoRect.minX / 1536, y: photoRect.minY / 1024,
                width: photoRect.width / 1536, height: photoRect.height / 1024)
            for observation in observations {
                XCTAssertTrue(normalized.contains(observation.boundingBox),
                    "Each line of the portrait quote and location must be inside the actual photo")
            }
            for x in [0.025, 0.975] {
                for y in [0.025, 0.975] {
                    let actual = try pixel(output, x: Int(photoRect.minX + x * photoRect.width),
                        y: Int(photoRect.minY + y * photoRect.height))
                    let expected = try pixel(photo, x: Int(x * Double(photo.width)), y: Int(y * Double(photo.height)))
                    XCTAssertEqual(actual.red, expected.red, accuracy: 0.025, "\(place), \(x),\(y)")
                    XCTAssertEqual(actual.green, expected.green, accuracy: 0.025, "\(place), \(x),\(y)")
                    XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.025, "\(place), \(x),\(y)")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
    }

    func testExportMapsUnsafeSourceDimensionsToInvalidImage() async throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try sourcePhoto(width: PostcardImageDecoder.maximumSourceDimension + 1, height: 1)
        let sourceURL = root.appendingPathComponent("postcards/sample/photo.png")
        try original.write(to: sourceURL)
        do {
            _ = try await PostcardExporter.pngData(event: event(place: "西湖湖边"), rootURL: root)
            XCTFail("Unsafe dimensions must not export")
        } catch PostcardExportError.invalidImage { }
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    private func assertOrientedExportMatchesUI(orientation: Int) async throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try orientedPhoto(orientation: orientation)
        let sourceURL = root.appendingPathComponent("postcards/sample/photo.png")
        try original.write(to: sourceURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation,
                       "The fixture must carry actual PNG orientation metadata")
        let uiPhoto = try PostcardImageDecoder.decodeThumbnail(data: original)
        XCTAssertEqual(uiPhoto.width, orientation == 6 ? 512 : 768)
        XCTAssertEqual(uiPhoto.height, orientation == 6 ? 768 : 512)
        let record = event(place: "西湖湖边")
        let reference = try render(PostcardScenicFaceView(event: record, rootURL: root,
            image: uiPhoto, analysis: try PostcardVisualAnalyzer.analyze(uiPhoto), style: .paperBorder), width: 768, height: 512)
        let output = try decode(await PostcardExporter.pngData(event: record, rootURL: root))
        XCTAssertEqual(output.width, 1536)
        XCTAssertEqual(output.height, 1024)
        // Four quadrant centers sample actual rendered photograph pixels. Rotating or
        // mirroring the source must move the same colors as the UI decoder does.
        for (x, y) in [(650, 260), (850, 260), (650, 650), (850, 650)] {
            let actual = try pixel(output, x: x, y: y)
            let expected = try pixel(reference, x: x, y: y)
            XCTAssertEqual(actual.red, expected.red, accuracy: 0.025, "orientation \(orientation), \(x),\(y)")
            XCTAssertEqual(actual.green, expected.green, accuracy: 0.025, "orientation \(orientation), \(x),\(y)")
            XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.025, "orientation \(orientation), \(x),\(y)")
        }
        try png(output).write(to: URL(fileURLWithPath: "/tmp/travelcat-export-orientation-\(orientation).png"))
        try png(reference).write(to: URL(fileURLWithPath: "/tmp/travelcat-export-orientation-\(orientation)-ui-reference.png"))
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    private func orientedPhoto(orientation: Int, edgeMarkers: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 768, height: 512, bitsPerComponent: 8,
            bytesPerRow: 768 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors: [CGColor] = [CGColor(red: 0.85, green: 0.12, blue: 0.12, alpha: 1),
            CGColor(red: 0.12, green: 0.75, blue: 0.20, alpha: 1),
            CGColor(red: 0.12, green: 0.25, blue: 0.90, alpha: 1),
            CGColor(red: 0.90, green: 0.75, blue: 0.12, alpha: 1)]
        for index in colors.indices {
            context.setFillColor(colors[index])
            context.fill(CGRect(x: (index % 2) * 384, y: (index / 2) * 256, width: 384, height: 256))
        }
        if edgeMarkers {
            // EXIF rotates these distinctive strips to the top and bottom;
            // center cropping must lose them and fail the preservation check.
            context.setFillColor(CGColor(red: 0.92, green: 0.18, blue: 0.76, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 512))
            context.setFillColor(CGColor(red: 0.14, green: 0.82, blue: 0.84, alpha: 1))
            context.fill(CGRect(x: 728, y: 0, width: 40, height: 512))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testStylesRemainStableForHistoricalCardsAndImageRetries() throws {
        for (place, expected) in [("西湖湖边", PostcardScenicStyle.paperBorder),
                                  ("古城宫殿", .journal), ("雪山徒步", .fullBleed),
                                  ("中央车站广场", .fullBleed), ("森林花园", .paperBorder)] {
            var record = event(place: place, version: nil)
            let original = record
            XCTAssertEqual(PostcardScenicStyle.resolve(event: record), expected)
            record.postcardStatus = .pendingImage
            record.postcardRelativePath = nil
            XCTAssertEqual(PostcardScenicStyle.resolve(event: record), expected)
            record.postcardStatus = original.postcardStatus
            record.postcardRelativePath = original.postcardRelativePath
            XCTAssertEqual(record, original)
            XCTAssertNil(record.postcardStyleVersion)
        }
        // Assert a fixed known selection as well as repeated calls: Swift's randomized
        // Hasher would otherwise pass a same-process-only repeatability test.
        // FNV-1a seed yields 3185983632095918784, remainder 0.
        XCTAssertEqual(PostcardScenicStyle.resolve(event: event(place: "旅途小憩")), .paperBorder)
    }

    func testMessageExportNeedsNoPhotoAndUsesRecipientAndTravelDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var record = event(place: "西湖湖边")
        record.postcardStatus = .pendingImage
        record.postcardRelativePath = nil
        let recipient = PostcardRecipientInfo(name: "小雨", address: "伦敦旅行路十二号", postalCode: "SW1A 1AA")
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        let output = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message,
            recipient: recipient, travelDate: date)
        let image = try decode(output)
        XCTAssertEqual(image.width, 1536)
        XCTAssertEqual(image.height, 1024)
        try PostcardRasterEvidence.write(PostcardRasterEvidence.postmark(image), tag: "date-export")
        XCTAssertEqual(PostcardMessageFaceView.postmarkDate(date), "2026.10.01")
        let datePixels = try PostcardRasterEvidence.pixels(PostcardRasterEvidence.postmark(image))
        for days in [1, 3] {
            let alternateDate = date.addingTimeInterval(TimeInterval(days * 86_400))
            let alternate = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message,
                recipient: recipient, travelDate: alternateDate)
            XCTAssertNotEqual(datePixels, try PostcardRasterEvidence.pixels(
                PostcardRasterEvidence.postmark(decode(alternate))),
                "Exported date glyphs must differ from 10.02/10.04")
        }
        let noDate = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message,
            recipient: recipient, travelDate: nil)
        XCTAssertNotEqual(datePixels, try PostcardRasterEvidence.pixels(
            PostcardRasterEvidence.postmark(decode(noDate))))
        let text = try recognizedText(image)
        XCTAssertTrue(text.contains("小雨"), text)
        XCTAssertTrue(text.contains("2026"), text)
        // OCR locates the date; crop controls above distinguish the exact day.
        XCTAssertTrue(text.contains("10."), text)
        XCTAssertTrue(text.contains("From"), text)
        // Vision sometimes reads this font's 1 as I. Compare the actual pixels against
        // both the wrong identifier and an absent identifier, without coaching OCR.
        let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
        let repeatedOutput = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message,
            recipient: recipient, travelDate: date)
        XCTAssertEqual(pixels, try XCTUnwrap(decode(repeatedOutput).dataProvider?.data) as Data)
        for alternateCode in ["SWIA 1AA", ""] {
            let alternateRecipient = PostcardRecipientInfo(name: recipient.name, address: recipient.address,
                postalCode: alternateCode)
            let alternateOutput = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message,
                recipient: alternateRecipient, travelDate: date)
            let alternateImage = try decode(alternateOutput)
            XCTAssertEqual(alternateImage.width, image.width)
            XCTAssertEqual(alternateImage.height, image.height)
            XCTAssertEqual(alternateImage.bytesPerRow, image.bytesPerRow)
            XCTAssertNotEqual(pixels, try XCTUnwrap(alternateImage.dataProvider?.data) as Data,
                "The exported postal identifier must have distinct, visible glyphs")
        }
        try output.write(to: URL(fileURLWithPath: "/tmp/travelcat-message-refinement-export.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Rendering must not initialize travel data")
    }

    func testMessageExportUsesDisplayedHomeSnapshotIncludingExplicitlyUnknownHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = event(place: "岭南天地", city: "佛山")
        let home = HomeLocation(country: "中国", city: "广州", source: .manual, updatedAt: Date(timeIntervalSince1970: 0))
        let store = HomeLocationStore(root: root)
        try store.save(.init(location: home))
        let original = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message)
        let unknown = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message, homeLocation: nil)
        try store.save(.init(location: .init(country: "法国", city: "巴黎", source: .manual, updatedAt: home.updatedAt)))
        let current = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message)
        let snapshot = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message, homeLocation: home)
        let stillUnknown = try await PostcardExporter.pngData(event: record, rootURL: root, face: .message, homeLocation: nil)
        func pixels(_ png: Data) throws -> Data { try XCTUnwrap(decode(png).dataProvider?.data) as Data }
        func assertSamePixels(_ first: Data, _ second: Data) throws {
            let a = [UInt8](try pixels(first)), b = [UInt8](try pixels(second))
            XCTAssertEqual(a.count, b.count)
            // ImageRenderer dithers this paper gradient by 1–2 levels between renders.
            // Check every channel; any layout, text or postage change is much larger.
            XCTAssertLessThanOrEqual(zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0, 2)
        }
        try assertSamePixels(original, snapshot)
        XCTAssertNotEqual(try pixels(original), try pixels(current))
        try assertSamePixels(unknown, stillUnknown)
        XCTAssertNotEqual(try pixels(unknown), try pixels(current))
    }

    func testCancelledExportDoesNotRenderEitherFace() async throws {
        let record = event(place: "西湖湖边")
        for face in PostcardFace.allCases {
            let task = Task { try await PostcardExporter.pngData(event: record,
                rootURL: URL(fileURLWithPath: "/tmp/no-postcard-source"), face: face) }
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled export must stop") }
            catch is CancellationError { }
        }
    }

    func testRegularHandwritingAndMissingTitleFontKeepChineseReadable() throws {
        let body = PostcardScenicTypography.bodyFont(size: 20)
        XCTAssertEqual(body.fontName, "LXGWWenKaiLite-Regular")
        XCTAssertFalse(body.fontDescriptor.symbolicTraits.contains(.bold))
        var characters = Array("猫旅风景心情".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(body as CTFont, &characters, &glyphs, characters.count))
        let fallback = PostcardScenicTypography.titleFont(category: .heritage, size: 20, lookup: { _, _ in nil })
        XCTAssertEqual(fallback.fontName, NSFont.systemFont(ofSize: 20, weight: .regular).fontName)
        let image = try render(Text("猫旅风景正好").font(Font(fallback)).foregroundStyle(.black)
            .padding(12).background(.white), width: 320, height: 80)
        XCTAssertTrue(try recognizedText(image).contains("风景正好"))
    }

    func testAllThreeScenicFacesRenderChineseAtCompactAndDetailSizesAndProducePreviews() throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Postcards/accepted-first.webp")
        let image = try decode(Data(contentsOf: fixture))
        let analysis = try PostcardVisualAnalyzer.analyze(image)
        for style in PostcardScenicStyle.allCases {
            for width in [320.0, 640.0] {
                let face = PostcardScenicFaceView(event: event(place: "江之岛海边"), rootURL: root,
                    image: image, analysis: analysis, style: style, profile: width == 320 ? .compact : .detail)
                let rendered = try render(face, width: width, height: width / 1.5)
                XCTAssertEqual(Double(rendered.width) / Double(rendered.height), 1.5, accuracy: 0.005)
                let text = try recognizedText(rendered)
                XCTAssertTrue(text.contains("风景正好"), "\(style), \(width): \(text)")
                try png(rendered).write(to: URL(fileURLWithPath: "/tmp/travelcat-scenic-\(style.rawValue)-\(Int(width)).png"))
            }
        }
    }

    func testUnknownFullBleedAnalysisKeepsMessageReadable() throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try decode(sourcePhoto())
        let rendered = try render(PostcardScenicFaceView(event: event(place: "雪山徒步"), rootURL: root,
            image: photo, analysis: nil, style: .fullBleed), width: 640, height: 640 / 1.5)
        XCTAssertTrue(try recognizedText(rendered).contains("风景正好"))
    }

    func testQuoteIsInsideActualPhotographInEveryStyleAndSize() throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A uniform blue photograph lets the test discover its actual rendered
        // boundary independently of the view's layout constants.
        let photo = try decode(sourcePhoto())
        let analysis = try PostcardVisualAnalyzer.analyze(photo)
        for style in PostcardScenicStyle.allCases {
            for width in [320.0, 640.0] {
                let rendered = try render(PostcardScenicFaceView(event: event(place: "西湖湖边"),
                    rootURL: root, image: photo, analysis: analysis, style: style,
                    profile: width == 320 ? .compact : .detail), width: width, height: width / 1.5)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.customWords = ["风景正好"]
                try VNImageRequestHandler(cgImage: rendered).perform([request])
                let quote = try XCTUnwrap(request.results?.first {
                    $0.topCandidates(1).first?.string.contains("风景正好") == true
                }, "Quote must remain readable: \(style), \(width)")
                let bounds = try bluePhotographBounds(rendered)
                XCTAssertTrue(bounds.contains(quote.boundingBox),
                    "Quote \(quote.boundingBox) must be within photo \(bounds): \(style), \(width)")
            }
        }
    }

    private func bluePhotographBounds(_ image: CGImage) throws -> CGRect {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var bounds = CGRect.null
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) {
                    let index = (y * image.width + x) * 4
                    if Int(pixels[index + 2]) - Int(pixels[index]) > 35 {
                        bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            XCTAssertFalse(bounds.isNull, "The rendered card must contain the fixture photograph")
            // Bitmap rows start at the top; Vision boxes start at the bottom.
            return CGRect(x: bounds.minX / CGFloat(image.width),
                y: 1 - bounds.maxY / CGFloat(image.height),
                width: bounds.width / CGFloat(image.width), height: bounds.height / CGFloat(image.height))
        }
    }

    func testLoadIdentityIncludesEventAndStatusWhenPhotoPathIsReused() {
        let first = event(place: "西湖湖边")
        let next = event(place: "西湖湖边", id: UUID())
        var waiting = first
        waiting.postcardStatus = .pendingImage
        let root = URL(fileURLWithPath: "/tmp/postcard-root")
        XCTAssertNotEqual(PostcardArtworkLoadIdentity.requestID(event: first, rootURL: root),
                          PostcardArtworkLoadIdentity.requestID(event: next, rootURL: root))
        XCTAssertNotEqual(PostcardArtworkLoadIdentity.requestID(event: first, rootURL: root),
                          PostcardArtworkLoadIdentity.requestID(event: waiting, rootURL: root))
    }

    func testLoadedPhotoInHiddenWindowAndEventReplacementDoNotEmitVisibilityCallback() async throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = event(place: "西湖湖边")
        let second = event(place: "西湖湖边", id: UUID())
        var callbacks: [(UUID, String)] = []
        let firstShown = expectation(description: "A hidden window must not consume the first postcard")
        let secondShown = expectation(description: "A hidden window must not consume a replacement postcard")
        firstShown.isInverted = true
        secondShown.isInverted = true
        let host = NSHostingView(rootView: PostcardScenicFaceView(event: first, rootURL: root, profile: .detail) { path in
            callbacks.append((first.id, path)); firstShown.fulfill()
        })
        let window = makeHiddenWindow(host)
        defer { withExtendedLifetime(window) {} }
        XCTAssertFalse(window.isVisible)
        await fulfillment(of: [firstShown], timeout: 0.4)
        host.rootView = PostcardScenicFaceView(event: second, rootURL: root, profile: .detail) { path in
            callbacks.append((second.id, path)); secondShown.fulfill()
        }
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [secondShown], timeout: 0.4)
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testVisibilityPolicyRequiresVisibleWindowAndActualImagePixels() {
        XCTAssertTrue(visibility().canReportVisibility)
        for (reason, hidden) in [
            ("hidden window", visibility(windowVisible: false)),
            ("miniaturized window", visibility(miniaturized: true)),
            ("occluded window", visibility(occluded: true)),
            ("closing window", visibility(closing: true)),
            ("hidden image ancestor", visibility(viewHidden: true)),
            ("image outside viewport", visibility(visibleRect: CGRect(x: 700, y: 0, width: 30, height: 30))),
            ("zero sized viewport", visibility(visibleRect: .zero)),
            ("paper margin only", visibility(visibleRect: CGRect(x: 0, y: 0, width: 15, height: 200))),
        ] {
            XCTAssertFalse(hidden.canReportVisibility, reason)
        }
        XCTAssertTrue(visibility(visibleRect: CGRect(x: 40, y: 40, width: 40, height: 40)).canReportVisibility)
    }

    func testVisibilityPolicyCanReportAfterRestoreOrScrollIntoView() {
        let lifecycle = [visibility(windowVisible: false), visibility(miniaturized: true),
            visibility(occluded: true), visibility(viewHidden: true),
            visibility(visibleRect: CGRect(x: 700, y: 0, width: 40, height: 40))]
        for before in lifecycle {
            XCTAssertFalse(before.canReportVisibility)
            XCTAssertTrue(visibility().canReportVisibility, "Visibility must be re-evaluated after restoration")
        }
    }

    func testClosedHiddenHostDoesNotReportPhotoAfterWindowLifecycleNotifications() async throws {
        let root = try sampleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shown = expectation(description: "Closing a hidden host must not consume the postcard")
        shown.isInverted = true
        let host = NSHostingView(rootView: PostcardScenicFaceView(event: event(place: "西湖湖边"),
            rootURL: root, profile: .detail) { _ in shown.fulfill() })
        let window = makeHiddenWindow(host)
        window.isReleasedWhenClosed = false
        window.close()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [shown], timeout: 0.4)
        withExtendedLifetime(window) {}
    }

    private func visibility(windowVisible: Bool = true, miniaturized: Bool = false,
        occluded: Bool = false, closing: Bool = false, viewHidden: Bool = false,
        visibleRect: CGRect = CGRect(x: 0, y: 0, width: 640, height: 426)) -> PostcardImageVisibilitySnapshot {
        .init(windowIsVisible: windowVisible, windowIsMiniaturized: miniaturized,
              windowIsOccluded: occluded, windowIsClosing: closing, viewIsHidden: viewHidden,
              imageRect: CGRect(x: 30, y: 30, width: 580, height: 360), visibleRect: visibleRect)
    }

    func testCorruptOrPendingPhotoDoesNotEmitVisibilityCallback() async throws {
        for pending in [false, true] {
            let root = try sampleRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            if !pending { try Data("broken image".utf8).write(to: root.appendingPathComponent("postcards/sample/photo.png")) }
            var record = event(place: "西湖湖边")
            if pending { record.postcardStatus = .pendingImage }
            let shown = expectation(description: "Unavailable picture must not count as displayed")
            shown.isInverted = true
            let host = NSHostingView(rootView: PostcardScenicFaceView(event: record, rootURL: root,
                profile: .detail) { _ in shown.fulfill() })
            let window = makeHiddenWindow(host)
            defer { withExtendedLifetime(window) {} }
            await fulfillment(of: [shown], timeout: 0.5)
        }
    }

    private func makeHiddenWindow<V: View>(_ view: NSHostingView<V>) -> NSWindow {
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 640 / 1.5)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["风景正好", "小雨"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func sampleRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("postcards/sample"), withIntermediateDirectories: true)
        try sourcePhoto().write(to: root.appendingPathComponent("postcards/sample/photo.png"))
        return root
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func event(place: String, city: String = "旅行城市", id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                       version: Int? = 1) -> TripEvent {
        TripEvent(id: id, tripID: UUID(),
            previousEventID: nil, occurredAt: Date(timeIntervalSince1970: 100), phase: .postcardReady,
            location: Location(country: "中国", city: city, place: place), transport: nil,
            summary: "一道小小的影子落在风景里。", mood: Mood(level: 0, label: "平静", quote: "风景正好。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .ready,
            postcardRelativePath: "postcards/sample/photo.png", postcardStyleVersion: version)
    }

    func testDamagedArtworkRevisionRefreshesCachedPixelsAndAnalysisToOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try TravelRepository(root: root)
        var record = event(place: "西湖湖边")
        let directory = "postcards/\(record.tripID.uuidString.lowercased())"
        let old = directory + "/original.png", new = directory + "/revision.png"
        record.postcardRelativePath = old
        try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        let original = try sourcePhoto(width: 1152, height: 768)
        let replacement = try sourcePhoto(width: 1152, height: 768, color: CGColor(red: 0.85, green: 0.08, blue: 0.12, alpha: 1))
        try original.write(to: root.appendingPathComponent(old)); try replacement.write(to: root.appendingPathComponent(new))
        let encoder = JSONEncoder.travelCat; encoder.outputFormatting = [.sortedKeys]
        try (encoder.encode(record) + Data("\n".utf8)).write(to: root.appendingPathComponent("journal/events.jsonl"))
        let store = try PostcardArtworkRevisionStore(root: root)
        let candidate = try XCTUnwrap(store.candidates().first)
        let hash = SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined()
        try store.install([.init(eventID: record.id, narrativeHash: candidate.narrativeHash,
            originalRelativePath: old, relativePath: new, contentHash: hash)])
        let taskBefore = PostcardArtworkLoadIdentity.requestID(event: record, rootURL: root)
        let revision = try await PostcardImageCache.shared.artwork(relativePath: old, rootURL: root)
        let revisionAnalysis = try await PostcardAnalysisCache.shared.analysis(for: revision.image,
            rootURL: root, relativePath: old, contentHash: revision.contentHash)
        try Data("broken".utf8).write(to: root.appendingPathComponent(new))
        let fallback = try await PostcardImageCache.shared.artwork(relativePath: old, rootURL: root)
        let fallbackAnalysis = try await PostcardAnalysisCache.shared.analysis(for: fallback.image,
            rootURL: root, relativePath: old, contentHash: fallback.contentHash)
        XCTAssertNotEqual(revision.contentHash, fallback.contentHash)
        XCTAssertEqual(try PostcardImageLoader.loadData(relativePath: old, rootURL: root), original)
        XCTAssertNotEqual(taskBefore, PostcardArtworkLoadIdentity.requestID(event: record, rootURL: root))
        XCTAssertNotEqual(revisionAnalysis, fallbackAnalysis)
        XCTAssertEqual(fallbackAnalysis, try PostcardVisualAnalyzer.analyze(fallback.image))
    }

    private func sourcePhoto(width: Int = 768, height: Int = 512,
        color: CGColor = CGColor(red: 0.35, green: 0.62, blue: 0.72, alpha: 1)) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: Double, green: Double, blue: Double) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            let i = (y * image.width + x) * 4
            return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
        }
    }
}

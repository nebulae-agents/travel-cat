import AppKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class PostcardLibraryTests: XCTestCase {
    func testExportRejectsNewFileThroughPhysicalDataDirectoryAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalPath = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physicalPath) }
        let destination = URL(fileURLWithPath: String(cString: physicalPath)).appendingPathComponent("new-export.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(PostcardExporter.isInsideDataRoot(destination, rootURL: root))
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-export.png")
        XCTAssertFalse(PostcardExporter.isInsideDataRoot(outside, rootURL: root))
    }

    func testAlbumMessageFaceKeepsPostalRolesVisibleInItsActualGridColumn() throws {
        var event = postcard(location: .init(country: "日本", city: "京都", place: "鸭川河畔"))
        event.postcardStatus = .pendingImage
        event.postcardRelativePath = nil
        let work = PostcardWorkItem(id: event.id, tripID: event.tripID, eventID: event.id,
            isSupplement: false, generatedAt: event.occurredAt, status: .pending)
        let view = NSHostingView(rootView: TripAlbumView(tripID: nil, events: [event], workItems: [work],
            unreadIDs: [event.id], open: { _ in }))
        view.frame = CGRect(x: 0, y: 0, width: 760, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { withExtendedLifetime(window) {} }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let bounds = try envelopePaperBounds(image)
        XCTAssertEqual(bounds.width / bounds.height, 1.5, accuracy: 0.03)
        try png(image).write(to: URL(fileURLWithPath: "/tmp/travelcat-album-envelope-grid.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        XCTAssertTrue(text.contains("未读"), text)
        for content in ["小黑", "亲爱", "京都", "鸭川河畔"] {
            XCTAssertTrue(text.contains(content), text)
        }
        XCTAssertTrue(text.contains("From"), text)
        for label in ["寄件人", "收件人", "待填写", "邮编", "翻看风景"] {
            XCTAssertFalse(text.contains(label), text)
        }
    }

    func testLongSenderLocationMessageFaceKeepsPostalRolesAndInformationVisible() throws {
        let event = postcard(location: .init(country: "波斯尼亚和黑塞哥维那", city: "萨拉热窝",
                               place: "巴什察尔希亚老城 · 塞比利喷泉旁的石板小巷"))
        let content = PostcardEnvelopeView(event: event).frame(width: 320)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        try png(image).write(to: URL(fileURLWithPath: "/tmp/travelcat-envelope-long-address.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        for content in ["小黑", "亲爱"] {
            XCTAssertTrue(text.contains(content), text)
        }
        XCTAssertTrue(text.contains("From"), text)
        for label in ["寄件人", "收件人", "待填写", "邮编", "翻看风景"] {
            XCTAssertFalse(text.contains(label), text)
        }
        for component in ["波斯尼亚和黑塞哥维那", "萨拉热窝", "巴什察尔希亚老城", "石板小巷"] {
            XCTAssertTrue(text.contains(component), text)
        }
    }

    func testLongPlaceMessageFaceKeepsItsLastWordsAndPostalRolesVisible() throws {
        let event = postcard(location: .init(country: "中国", city: "北京",
            place: "天坛公园祈年殿西侧七十二长廊尽头靠近丹陛桥北侧红墙石板步道与百年古柏树林树荫交汇处"))
        let renderer = ImageRenderer(content: PostcardEnvelopeView(event: event).frame(width: 320))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        try png(image).write(to: URL(fileURLWithPath: "/tmp/travelcat-envelope-long-place.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        XCTAssertTrue(text.contains("交汇处"), text)
        XCTAssertTrue(text.contains("From"), text)
        for label in ["寄件人", "收件人", "待填写", "邮编", "翻看风景"] {
            XCTAssertFalse(text.contains(label), text)
        }
    }

    func testSealedCardOnlyRevealsAddressAndLocationSearchDoesNotRevealStory() {
        let event = postcard()
        let unread: Set<UUID> = [event.id]
        XCTAssertTrue(PostcardLibrary.isSealed(event, unreadIDs: unread))
        XCTAssertFalse(PostcardLibrary.isSealed(event, unreadIDs: []))
        var waiting = event
        waiting.postcardStatus = .pendingImage
        XCTAssertTrue(PostcardLibrary.isSealed(waiting, unreadIDs: unread))
        waiting.postcardStatus = .imageUnavailable
        XCTAssertTrue(PostcardLibrary.isSealed(waiting, unreadIDs: unread))
        waiting.postcardStatus = .rejected
        XCTAssertFalse(PostcardLibrary.isSealed(waiting, unreadIDs: unread))
        XCTAssertEqual(PostcardDisplayLocation().resolveSpoken(event.location), "中国 · 杭州 · 西湖湖边")
        XCTAssertTrue(PostcardLibrary.matches(event, filter: .unread, query: "杭州", unreadIDs: unread, favouriteIDs: []))
        XCTAssertFalse(PostcardLibrary.matches(event, filter: .all, query: "秘密发现", unreadIDs: unread, favouriteIDs: []))
        XCTAssertFalse(PostcardLibrary.matches(event, filter: .favourites, query: "", unreadIDs: unread, favouriteIDs: []))
        XCTAssertTrue(PostcardLibrary.matches(event, filter: .favourites, query: "中国", unreadIDs: unread, favouriteIDs: [event.id]))
        XCTAssertEqual(PostcardDisplayLocation().resolveSpoken(.init(country: "中国", city: "", place: "")), "中国")
        XCTAssertEqual(PostcardDisplayLocation().resolveSpoken(nil), "旅途中")
    }

    func testMessageFaceRendersAtCompactAndLargeSizesWithoutSourceImage() throws {
        for width in [320.0, 640.0] {
            let content = PostcardEnvelopeView(event: postcard()).frame(width: width)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(width * 2))
            XCTAssertEqual(Double(image.height), width * 2 / 1.5, accuracy: 1)
            if width == 640 { try png(image).write(to: URL(fileURLWithPath: "/tmp/travelcat-envelope-preview.png")) }
        }
    }

    func testRenderedExportIsThreeByTwoAndPreservesSourceAndReadState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("postcards/trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceURL = folder.appendingPathComponent("card.png")
        let image = try fixtureImage()
        let original = try png(image)
        try original.write(to: sourceURL)
        let event = postcard()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(snapshot: .empty(now: Date()), events: [event], dataRoot: root, defaults: defaults)
        let exported = try await PostcardExporter.pngData(event: event, rootURL: root)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(exported as CFData, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(result.width, 1536)
        XCTAssertEqual(result.height, 1024)
        XCTAssertNotEqual(exported, original)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        XCTAssertEqual(model.unreadPostcardIDs, [event.id])
        try exported.write(to: URL(fileURLWithPath: "/tmp/travelcat-export-preview.png"))
    }

    func testExportRejectsMissingCorruptAndUnavailablePhoto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("postcards/trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceURL = folder.appendingPathComponent("card.png")
        for data in [nil, Data("broken source".utf8)] as [Data?] {
            if let data { try data.write(to: sourceURL) }
            do { _ = try await PostcardExporter.pngData(event: postcard(), rootURL: root); XCTFail("Invalid source must not export") }
            catch { }
            if let data { XCTAssertEqual(try Data(contentsOf: sourceURL), data) }
        }
        var unavailable = postcard()
        unavailable.postcardStatus = .pendingImage
        do { _ = try await PostcardExporter.pngData(event: unavailable, rootURL: root); XCTFail("Pending photo must not export") }
        catch PostcardExportError.unavailable { }
    }

    func testExportSupportsPreservedWebPAndSquareHistoricalPhotos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("postcards/trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Postcards/accepted-first.webp")
        let sources = [("card.webp", try Data(contentsOf: fixture)), ("card.png", try png(fixtureImage(width: 768, height: 768)))]
        for (name, original) in sources {
            let url = folder.appendingPathComponent(name)
            try original.write(to: url)
            var event = postcard()
            event.postcardRelativePath = "postcards/trip/\(name)"
            let output = try await PostcardExporter.pngData(event: event, rootURL: root)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1536)
            XCTAssertEqual(image.height, 1024)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    private func postcard(location: Location = .init(country: "中国", city: "杭州", place: "西湖湖边")) -> TripEvent {
        .init(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, tripID: UUID(), previousEventID: nil,
              occurredAt: Date(timeIntervalSince1970: 1000), phase: .postcardReady,
              location: location, transport: nil,
              summary: "秘密发现藏在这封信里。", mood: .init(level: 0, label: "平静", quote: "湖边的风很轻。"),
              continuityReferences: ["湖边"], openHook: nil, consumedItemID: nil,
              postcardStatus: .ready, postcardRelativePath: "postcards/trip/card.png", postcardStyleVersion: 1)
    }

    private func fixtureImage(width: Int = 1536, height: Int = 1024) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.65, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.08, green: 0.06, blue: 0.09, alpha: 1))
        context.fillEllipse(in: CGRect(x: 200, y: 180, width: 350, height: 430))
        return try XCTUnwrap(context.makeImage())
    }

    private func envelopePaperBounds(_ image: CGImage) throws -> CGRect {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    if r > 235, g > 230, b > 220, r >= g, g - b > 2 {
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX, "Envelope paper must be visible")
        XCTAssertGreaterThan(maxY, minY)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

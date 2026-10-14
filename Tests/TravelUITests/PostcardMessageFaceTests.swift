import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class PostcardMessageFaceTests: XCTestCase {
    func testRecipientDefaultsLeavePersonalAddressAndPostalCodeEmpty() {
        XCTAssertEqual(PostcardRecipientInfo.empty, .init(name: "亲爱的你", address: "", postalCode: ""))
        XCTAssertEqual(PostcardRecipientInfo(name: " \n ", address: " \n", postalCode: " ").normalized,
                       .empty)
    }

    func testNormalizationPreservesInternationalPostalCodesAndAddressLines() throws {
        for code in ["SW1A 1AA", "H2Z 1A4", "12345-6789"] {
            let original = PostcardRecipientInfo(name: " 小雨 ", address: "  First line\nSecond line  ",
                                                 postalCode: " \(code) ")
            let normalized = original.normalized
            XCTAssertEqual(normalized.name, "小雨")
            XCTAssertEqual(normalized.address, "First line\nSecond line")
            XCTAssertEqual(normalized.postalCode, code)
            XCTAssertEqual(try JSONDecoder().decode(PostcardRecipientInfo.self,
                from: JSONEncoder().encode(normalized)), normalized)
        }
    }

    func testAccessibleMessageKeepsFullSourceAndRecipientWithoutRevealingStory() {
        let recipient = PostcardRecipientInfo(name: "小雨", address: String(repeating: "完整地址信息", count: 20),
                                             postalCode: "SW1A 1AA")
        let event = postcard()
        let face = PostcardMessageFaceView(event: event, recipient: recipient)
        let label = face.completeAccessibilityLabel
        XCTAssertTrue(label.contains(event.mood.quote))
        XCTAssertTrue(label.contains(event.location!.place))
        XCTAssertTrue(label.contains(recipient.address))
        XCTAssertTrue(label.contains("SW1A 1AA"))
        XCTAssertTrue(label.contains("旅行日期待确认"))
        XCTAssertFalse(label.contains(event.summary))
        XCTAssertFalse(label.contains("1970"), "The event publication date is not an inferred travel date")
    }

    func testRecordedDateGlyphsStayDistinctAtBothCardSizesAndEveryFare() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        let event = postcard(location: .init(country: "中国", city: "佛山", place: "岭南天地巷口的木窗旁"))
        for (city, country) in [("佛山", "中国"), ("广州", "中国"), ("北京", "中国"), ("巴黎", "法国")] {
            let home = HomeLocation(country: country, city: city, source: .manual, updatedAt: date)
            for width in [320.0, 640.0] {
                let draw: (Date?) throws -> CGImage = { value in
                    try self.raster(PostcardMessageFaceView(event: event, travelDate: value,
                                                           homeLocation: home), width: width)
                }
                try PostcardRasterEvidence.assertRecordedDay(draw(date), date: date, render: draw)
            }
        }
    }

    func testKnownTravelDateIsReadableAtCompactAndLargeSizes() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        let event = postcard()
        for width in [320.0, 640.0] {
            let (image, observations) = try render(PostcardMessageFaceView(event: event, travelDate: date), width: width)
            try PostcardRasterEvidence.assertRecordedDay(image, date: date) { value in
                try self.raster(PostcardMessageFaceView(event: event, travelDate: value), width: width)
            }
            try png(image).write(to: URL(fileURLWithPath: "/tmp/travelcat-message-date-\(Int(width)).png"))
            try PostcardRasterEvidence.write(PostcardRasterEvidence.postmark(image),
                                             tag: "date-known-\(Int(width))")
            // OCR may read 01 as 02/04 on older Vision models. Use it for line
            // position and legibility; exact day glyphs are checked above.
            let dateLabel = try XCTUnwrap(observations.first {
                $0.topCandidates(1).first?.string.contains("10.") == true
            })
            XCTAssertGreaterThan(dateLabel.boundingBox.height, 0.025, "Travel date needs readable type")
            XCTAssertGreaterThan(dateLabel.boundingBox.midX, 0.82, "The dated cancellation must be over the upper-right stamp")
            XCTAssertTrue(observations.contains { $0.topCandidates(1).first?.string.contains("2026") == true })
            XCTAssertEqual(observations.filter {
                $0.topCandidates(1).first?.string.contains("10.") == true
            }.count, 1)
        }
    }

    func testDistanceStampVariantsFitWithLongRecipientAndMatchFare() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        let event = postcard(location: .init(country: "中国", city: "佛山", place: "岭南天地巷口的木窗旁"))
        let recipient = PostcardRecipientInfo(name: "住在远方的旅行伙伴小雨",
            address: "英国伦敦威斯敏斯特区一条很长的街道门牌信息与公寓楼层及收件处说明", postalCode: "SW1A 1AA")
        for (city, country, expected) in [("佛山", "中国", 1), ("广州", "中国", 2), ("北京", "中国", 3), ("巴黎", "法国", 5)] {
            let home = HomeLocation(country: country, city: city, source: .manual, updatedAt: date)
            let face = PostcardMessageFaceView(event: event, recipient: recipient, travelDate: date, homeLocation: home)
            XCTAssertTrue(face.completeAccessibilityLabel.contains("虚拟邮资 \(expected) 猫邮币"))
            for width in [320.0, 640.0] {
                let (image, observations) = try render(face, width: width)
                try png(image).write(to: URL(fileURLWithPath: "/tmp/travelcat-stamps-\(expected)-\(Int(width)).png"))
                try PostcardRasterEvidence.write(PostcardRasterEvidence.postmark(image),
                                                 tag: "date-fare-\(expected)-\(Int(width))")
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
                XCTAssertTrue(text.contains("2026"), text)
                XCTAssertTrue(text.contains("10."), text)
                XCTAssertTrue(text.contains("旅行伙伴"), text)
                XCTAssertTrue(text.contains("收件处说明"), text)
                XCTAssertTrue(text.contains("木窗旁"), text)
                for observation in observations {
                    XCTAssertGreaterThan(observation.boundingBox.minY, 0.025)
                    XCTAssertLessThan(observation.boundingBox.maxY, 0.98)
                }
            }
        }
    }

    func testUnknownSupplementDateSentinelNeverBecomesAPostmark() throws {
        let face = PostcardMessageFaceView(event: postcard(), travelDate: TripAlbumChronology.unknownDate)
        XCTAssertNil(face.travelDate)
        XCTAssertTrue(face.completeAccessibilityLabel.contains("旅行日期待确认"))
        let (_, observations) = try render(face, width: 320)
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
        XCTAssertFalse(text.contains("4001"), text)
        XCTAssertFalse(text.contains("2026"), text)
    }

    func testLongRecipientAndSenderKeepPostalRolesAndInformationInsideBothCardSizes() throws {
        let recipient = PostcardRecipientInfo(name: "住在远方的旅行伙伴小雨",
            address: "英国伦敦威斯敏斯特区一条很长的街道门牌信息与公寓楼层及收件处说明",
            postalCode: "SW1A 1AA")
        let event = postcard()
        for width in [320.0, 640.0] {
            let (image, observations) = try render(PostcardMessageFaceView(event: event, recipient: recipient), width: width)
            try png(image).write(to: URL(fileURLWithPath: "/tmp/travelcat-message-recipient-\(Int(width)).png"))
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
            XCTAssertTrue(text.contains("交汇处"), text)
            XCTAssertTrue(text.contains("旅行伙伴"), text)
            XCTAssertTrue(text.contains("From"), text)
            // Separate boxes are not a continuous OCR word. Compare the actual glyph pixels
            // against a 1/I substitution while keeping every other field identical.
            var alternate = recipient
            alternate.postalCode = "SWIA 1AA"
            let (alternateImage, _) = try render(PostcardMessageFaceView(event: event, recipient: alternate), width: width)
            XCTAssertNotEqual(try XCTUnwrap(image.dataProvider?.data) as Data,
                try XCTUnwrap(alternateImage.dataProvider?.data) as Data)
            XCTAssertFalse(text.contains("秘密故事"), text)
            for label in ["寄件人", "收件人", "邮编", "翻看风景"] {
                XCTAssertFalse(text.contains(label), text)
            }
            for observation in observations {
                XCTAssertGreaterThan(observation.boundingBox.minY, 0.025)
                XCTAssertLessThan(observation.boundingBox.maxY, 0.98)
            }
            XCTAssertEqual(Double(image.width) / Double(image.height), 1.5, accuracy: 0.005)
        }
    }

    func testReadMessageAndEmptyAddressRemainQuietAndAccessible() throws {
        let face = PostcardMessageFaceView(event: postcard(location: nil), isUnread: false)
        let (image, observations) = try render(face, width: 320)
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
        XCTAssertTrue(text.contains("旅途中"), text)
        XCTAssertTrue(text.contains("亲爱"), text)
        XCTAssertTrue(text.contains("From"), text)
        XCTAssertTrue(face.completeAccessibilityLabel.contains("收件人亲爱的你"))
        XCTAssertTrue(face.completeAccessibilityLabel.contains("地址待填写"))
        XCTAssertTrue(face.completeAccessibilityLabel.contains("邮编待填写"))
        for label in ["旅行短笺", "寄件人", "收件人", "待填写", "邮编"] {
            XCTAssertFalse(text.contains(label), text)
        }
        XCTAssertFalse(text.contains("未读"), text)
        XCTAssertFalse(text.contains("秘密故事"), text)
        XCTAssertEqual(Double(image.width) / Double(image.height), 1.5, accuracy: 0.005)
    }

    func testOversizedRecordedLocationCannotCoverRecipientAndPostalRoles() throws {
        let event = postcard(location: .init(country: String(repeating: "很长的国家名称", count: 40), city: "城市",
                                             place: String(repeating: "很长的地点说明", count: 60)))
        let face = PostcardMessageFaceView(event: event)
        let (_, observations) = try render(face, width: 320)
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
        XCTAssertTrue(text.contains("亲爱"), text)
        XCTAssertTrue(text.contains("From"), text)
        for label in ["寄件人", "收件人", "待填写", "邮编", "翻看风景"] {
            XCTAssertFalse(text.contains(label), text)
        }
        XCTAssertTrue(face.completeAccessibilityLabel.contains(event.location!.country))
        XCTAssertTrue(face.completeAccessibilityLabel.contains(event.location!.place))
    }

    private func postcard(location: Location? = .init(country: "波斯尼亚和黑塞哥维那", city: "萨拉热窝",
        place: "天坛公园祈年殿西侧七十二长廊尽头靠近丹陛桥北侧红墙石板步道与百年古柏树林树荫交汇处")) -> TripEvent {
        .init(id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 1000), phase: .postcardReady,
            location: location, transport: nil, summary: "秘密故事只在外部详情展示。",
            mood: .init(level: 0, label: "平静", quote: "晚风拂过树梢，远方的灯火亮了起来，我把这份宁静装进明信片里寄给你。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .pendingImage, postcardRelativePath: nil)
    }

    private func raster(_ face: PostcardMessageFaceView, width: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: face.frame(width: width))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func render(_ face: PostcardMessageFaceView, width: CGFloat) throws -> (CGImage, [VNRecognizedTextObservation]) {
        let image = try raster(face, width: width)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["亲爱的你"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (image, request.results ?? [])
    }

    private func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

}

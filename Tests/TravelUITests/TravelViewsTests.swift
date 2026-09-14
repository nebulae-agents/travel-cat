import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import TravelCore
import TravelStorage
@testable import TravelUI

final class TravelViewsTests: XCTestCase {
    func testNormalArtworkIntegrationMatrixKeepsMoodFontInkAndPawSemantics() throws {
        let cases: [(Mood, PostcardHandwritingFamily, String, PostcardPawImpression)] = [
            (Mood(level: 0, label: "平静", quote: "慢慢看风景。"), .serene, "LXGWWenKaiLite-Medium", .balanced),
            (Mood(level: 1, label: "好奇", quote: "前面会有什么？"), .playful, "LXGWWenKaiLite-Medium", .lively),
            (Mood(level: -2, label: "想家", quote: "有一点想念。"), .reflective, "LXGWWenKaiLite-Regular", .light),
            (Mood(level: 4, label: "坚定", quote: "继续往前走。"), .bold, "LXGWWenKaiLite-Medium", .firm),
        ]
        let profiles: [(PostcardOverlayProfile, CGSize)] = [
            (.detail, CGSize(width: 520, height: 230)),
            (.compact, CGSize(width: 322, height: 120)),
        ]
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.72, red: 0.20, green: 0.54, blue: 0.82)
        )

        for (mood, family, expectedFace, impression) in cases {
            let metadata = PostcardArtworkMetadata(event: postcardEvent(location: nil, mood: mood))
            for (profile, size) in profiles {
                let layout = PostcardArtworkLayoutResolver.resolve(
                    metadata: metadata,
                    analysis: analysis,
                    profile: profile,
                    containerSize: size
                )
                let measuredFont = try XCTUnwrap(PostcardOverlayTypography.measurementFont(
                    fontSize: layout.messageFontSize,
                    handwriting: layout.handwritingStyle
                ))

                XCTAssertEqual(metadata.mood, mood, "\(family) \(profile)")
                XCTAssertEqual(layout.handwritingStyle.family, family, "\(family) \(profile)")
                XCTAssertEqual(layout.handwritingStyle.fontPostScriptName, expectedFace, "\(family) \(profile)")
                XCTAssertEqual(layout.messageFont.fontName, measuredFont.fontName, "\(family) \(profile)")
                XCTAssertEqual(layout.messageFont.fontName, layout.handwritingStyle.fontPostScriptName, "\(family) \(profile)")
                let traits = try XCTUnwrap(
                    layout.messageFont.fontDescriptor.object(forKey: .traits)
                        as? [NSFontDescriptor.TraitKey: Any]
                )
                let actualWeight = try XCTUnwrap(traits[.weight] as? NSNumber).doubleValue
                XCTAssertEqual(actualWeight, layout.handwritingStyle.fontWeight, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(layout.messageFontSize, profile == .detail ? 17 : 12)
                XCTAssertEqual(layout.inkStyle.sceneFamily, .lakeBlue, "\(family) \(profile)")
                XCTAssertEqual(layout.pawSignature.style.color, layout.inkStyle.foreground, "\(family) \(profile)")
                XCTAssertEqual(layout.pawSignature.style.opacity, layout.inkStyle.pawOpacity, "\(family) \(profile)")
                XCTAssertEqual(layout.pawSignature.style.impression, impression, "\(family) \(profile)")
            }
        }
    }

    func testProductionLineSpacingNeverRequestsUnsupportedNegativeSwiftUISpacing() {
        let moods = [
            Mood(level: 2, label: "欣喜", quote: "湖光和晨风一起把旧码头点亮了。"),
            Mood(level: 2, label: "兴奋", quote: "我追上了潮汐写出的金色路线。"),
            Mood(level: 2, label: "惊喜", quote: "桥、清水和山峰终于都在同一幅画里。"),
        ]
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.62, red: 0.18, green: 0.46, blue: 0.68)
        )

        for mood in moods {
            for (profile, size) in [
                (PostcardOverlayProfile.detail, CGSize(width: 520, height: 230)),
                (.compact, CGSize(width: 322, height: 120)),
            ] {
                let metadata = PostcardArtworkMetadata(event: postcardEvent(location: nil, mood: mood))
                let layout = PostcardArtworkLayoutResolver.resolve(
                    metadata: metadata,
                    analysis: analysis,
                    profile: profile,
                    containerSize: size
                )

                XCTAssertGreaterThanOrEqual(layout.messageLineSpacing, 0, "\(mood.label) \(profile)")
                XCTAssertLessThanOrEqual(layout.pawSignature.placement.measuredLineCount, 2)
                XCTAssertEqual(layout.messagePlacement, .belowImage, "No subject boundary means a separate caption")
                XCTAssertEqual(layout.pawSignature.placement.mode, .omitted)
            }
        }
    }

    func testProductionSourcesHaveNoLegacyRoundedItalicOrBooleanInkConstructionPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let overlay = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardOverlayLayout.swift"))
        let ink = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardInkStyle.swift"))

        XCTAssertFalse(overlay.contains("legacyMeasurementFont"))
        XCTAssertFalse(overlay.contains("symbolicTraits.union(.italic)"))
        XCTAssertFalse(overlay.contains("usesLightText: Bool,\n        accent:"))
        XCTAssertFalse(overlay.contains("PostcardInkResolver.legacyStyle"))
        XCTAssertFalse(ink.contains("static func legacyStyle"))
    }

    func testPostcardMetadataRetainsMoodAndPresentationUsesItForNormalAndPendingAnalysis() {
        let mood = Mood(level: -2, label: "想家", quote: "风吹过的时候，有一点想家。")
        let event = postcardEvent(
            location: Location(country: "日本", city: "宫岛", place: "严岛神社"),
            mood: mood
        )
        let metadata = PostcardArtworkMetadata(event: event)
        let size = CGSize(width: 520, height: 230)
        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.72, red: 0.82, green: 0.34, blue: 0.14)
        )

        let resolved = PostcardArtworkLayoutResolver.resolve(
            metadata: metadata,
            analysis: analysis,
            profile: .detail,
            containerSize: size
        )
        let pending = PostcardArtworkLayoutResolver.resolve(
            metadata: metadata,
            analysis: nil,
            profile: .detail,
            containerSize: size
        )

        XCTAssertEqual(metadata.mood, mood)
        XCTAssertEqual(resolved.handwritingStyle.family, .reflective)
        XCTAssertEqual(resolved.inkStyle.sceneFamily, .warmEarth)
        XCTAssertEqual(pending.handwritingStyle.family, .serene)
        XCTAssertEqual(pending.inkStyle, PostcardInkResolver.unknownStyle)
        XCTAssertEqual(pending.inkStyle.foreground, .init(red: 1, green: 1, blue: 1))
        XCTAssertEqual(pending.inkStyle.wash, .init(red: 0, green: 0, blue: 0))
    }

    func testUnknownMoodUsesDeterministicLevelAndUnknownAnalysisKeepsReadableFallback() {
        let mood = Mood(level: 1, label: "???", quote: "仍然会写下完整寄语。")
        let metadata = PostcardArtworkMetadata(event: postcardEvent(location: nil, mood: mood))

        let analysis = PostcardVisualAnalysis(
            salientRegions: [],
            samples: .uniform(luminance: 0.66, red: 0.20, green: 0.54, blue: 0.82)
        )
        let first = PostcardArtworkLayoutResolver.resolve(
            metadata: metadata,
            analysis: analysis,
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )
        let second = PostcardArtworkLayoutResolver.resolve(
            metadata: metadata,
            analysis: analysis,
            profile: .compact,
            containerSize: CGSize(width: 322, height: 120)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.handwritingStyle.family, .playful)
        XCTAssertGreaterThanOrEqual(first.inkStyle.minimumContrastRatio, 4.5)
        XCTAssertTrue(first.pawSignature.placement.messageFits)
    }

    func testMalformedAnalysisUsesSereneReadableFallbackInsteadOfSceneStyling() {
        let mood = Mood(level: 5, label: "惊喜", quote: "坏掉的分析也不能吞掉这句话。")
        let metadata = PostcardArtworkMetadata(event: postcardEvent(location: nil, mood: mood))
        let malformed = PostcardVisualAnalysis(
            salientRegions: [],
            samples: PostcardSampleGrid(columns: 3, rows: 3, values: [])
        )

        let layout = PostcardArtworkLayoutResolver.resolve(
            metadata: metadata,
            analysis: malformed,
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230)
        )

        XCTAssertEqual(layout.handwritingStyle.family, .serene)
        XCTAssertEqual(layout.inkStyle, PostcardInkResolver.unknownStyle)
        XCTAssertTrue(layout.pawSignature.placement.messageFits)
    }

    func testPostcardArtworkSourceConsumesOnlySemanticTypographyInkAndPawStyles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardArtworkView.swift"))
        let textSource = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardMessageText.swift"))

        XCTAssertTrue(source.contains("PostcardMessageTextView("))
        XCTAssertTrue(source.contains("layout.messageTextLayout("))
        XCTAssertTrue(textSource.contains(".font(Font(layout.font))"))
        XCTAssertTrue(source.contains("metadata.fullMessage"))
        XCTAssertTrue(source.contains("color(layout.inkStyle.foreground)"))
        XCTAssertTrue(source.contains("color(layout.inkStyle.wash)"))
        XCTAssertTrue(source.contains("color(layout.inkStyle.shadow)"))
        XCTAssertTrue(source.contains("layout.inkStyle.shadowOpacity"))
        XCTAssertTrue(source.contains("layout.inkStyle.shadowRadius"))
        XCTAssertTrue(source.contains("layout.locationInkStyle"))
        XCTAssertTrue(source.contains("PostcardLocationLabelView("))
        XCTAssertTrue(source.contains("ink: locationInk"))
        XCTAssertTrue(source.contains("color(ink.foreground)"))
        XCTAssertTrue(source.contains("color(ink.shadow)"))
        XCTAssertTrue(source.contains("ink.shadowOpacity"))
        XCTAssertTrue(source.contains("ink.opacity"))
        XCTAssertTrue(source.contains("weight: .medium"))
        XCTAssertTrue(source.contains("PostcardPawSignatureView(signature: layout.pawSignature)"))
        XCTAssertFalse(source.contains("Capsule"))
        XCTAssertFalse(source.contains(".thinMaterial"))
        XCTAssertFalse(source.contains("locationPaperColor"))
        XCTAssertFalse(source.contains("locationPaperTint"))
        XCTAssertFalse(source.contains("caption.weight(.semibold)"))
        XCTAssertFalse(source.contains("layout.usesLightText ? Color.white : Color.black"))
        XCTAssertFalse(source.contains("let washColor = layout.usesLightText"))
        XCTAssertFalse(source.contains(".system(size:"))
        XCTAssertFalse(source.contains(".italic()"))
        XCTAssertFalse(source.contains(".bold()"))
    }

    func testPawSignatureSourceIsHiddenAndHasNoTextGlyphAccessibility() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardPawSignature.swift"))

        XCTAssertTrue(source.contains(".accessibilityHidden(PostcardPawSignatureStyle.isAccessibilityHidden)"))
        XCTAssertTrue(source.contains("ink.opacity(style.opacity)"))
        XCTAssertFalse(source.contains("🐾"))
        XCTAssertFalse(source.contains("accessibilityLabel"))
        XCTAssertFalse(source.contains("Image(systemName:"))
        XCTAssertFalse(source.contains("NSImage"))
        XCTAssertFalse(source.contains("CGImage"))
    }

    func testMessageOverlayUsesTopAlignedFrameSharedWithPawCoordinates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardArtworkView.swift"))
        let textSource = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardMessageText.swift"))
        XCTAssertTrue(source.contains("PostcardMessageTextView("))
        XCTAssertTrue(textSource.contains("alignment: .topLeading"))
    }

    func testMessageOverlayUsesMeasuredHandwritingWithoutImplicitScale() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardArtworkView.swift"))
        let textSource = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/PostcardMessageText.swift"))

        XCTAssertTrue(textSource.contains(".font(Font(layout.font))"))
        XCTAssertFalse(source.contains(".fontWeight(.semibold)"))
        XCTAssertFalse(source.contains(".minimumScaleFactor(0.72)"))
        XCTAssertTrue(source.contains("PostcardArtworkLayoutResolver.resolve"))
    }

    func testAlbumProductionGridKeepsFullHistoricalMessageAndWidensItsCard() {
        let availableWidth: CGFloat = 696
        let ordinary = "湖光和晨风一起把旧码头点亮了。"
        let long = String(repeating: "旅", count: 80)

        let ordinaryLayout = TripAlbumLayout.geometry(
            availableWidth: availableWidth,
            messages: [ordinary]
        )
        XCTAssertEqual(ordinaryLayout.columnCount, 2)
        XCTAssertGreaterThanOrEqual(ordinaryLayout.artworkWidth, 320)

        let longLayout = TripAlbumLayout.geometry(
            availableWidth: availableWidth,
            messages: [PostcardVisualMessage.resolve(long)]
        )
        XCTAssertEqual(longLayout.columnCount, 1)
        XCTAssertGreaterThanOrEqual(longLayout.artworkWidth, 320)

        let undersized = TripAlbumLayout.geometry(
            availableWidth: 300,
            messages: [ordinary]
        )
        XCTAssertEqual(undersized.artworkWidth, 280)
        XCTAssertFalse(undersized.isReadable)
        XCTAssertEqual(TripAlbumLayout.minimumWindowContentWidth, 760)
        XCTAssertEqual(TripAlbumLayout.artworkHeight, 120)
    }

    func testAlbumLayoutMinimumContentHeightIncludesDateSectionsAndClampsNegativeCounts() {
        XCTAssertEqual(TripAlbumLayout.minimumContentHeight(eventCount: 6, dateGroupCount: 3), 1086)
        XCTAssertEqual(TripAlbumLayout.minimumContentHeight(eventCount: -1, dateGroupCount: -2), 0)
        XCTAssertEqual(TripAlbumLayout.dateGroupSpacing, 16)
        XCTAssertEqual(TripAlbumLayout.dateHeaderHeightContribution, 32)
    }

    func testAlbumLayoutRemainsReadableWithTwoColumnsAtMinimumWindowWidth() {
        let layout = TripAlbumLayout.geometry(
            availableWidth: TripAlbumLayout.minimumWindowContentWidth,
            messages: ["湖光和晨风一起把旧码头点亮了。"]
        )

        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertGreaterThanOrEqual(layout.artworkWidth, TripAlbumLayout.readableCompactArtworkWidth)
        XCTAssertTrue(layout.isReadable)
    }

    @MainActor
    func testAlbumRendersGroupedCardsAtWideAndNarrowWidthsWithNaturalScrollContent() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tripID = UUID()
        let longCard = event(
            id: UUID(),
            tripID: tripID,
            at: 0,
            summary: String(repeating: "沿着海岸慢慢走，收集一整天的风和浪。", count: 30)
        )
        let events = [
            longCard,
            event(id: UUID(), tripID: tripID, at: 60),
            event(id: UUID(), tripID: tripID, at: 86_400),
            event(id: UUID(), tripID: tripID, at: 86_460),
        ]
        let ordered = TripAlbumView.orderedEvents(tripID: tripID, events: events)
        let groups = TripAlbumDateGrouping.groups(orderedEvents: ordered, calendar: calendar)
        let messages = ordered.map { PostcardArtworkMetadata(event: $0).visualMessage }

        let wideLayout = TripAlbumLayout.geometry(
            availableWidth: TripAlbumLayout.minimumWindowContentWidth,
            messages: messages
        )
        let narrowLayout = TripAlbumLayout.geometry(availableWidth: 500, messages: messages)
        XCTAssertEqual(wideLayout.columnCount, 2)
        XCTAssertEqual(narrowLayout.columnCount, 1)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(TripAlbumLayout.minimumContentHeight(eventCount: 1, dateGroupCount: 1), 197)
        XCTAssertEqual(
            TripAlbumLayout.minimumContentHeight(eventCount: ordered.count, dateGroupCount: groups.count),
            724
        )

        let wideView = NSHostingView(rootView: TripAlbumView(
            tripID: tripID,
            events: events,
            calendar: calendar,
            open: { _ in }
        ))
        wideView.frame = CGRect(x: 0, y: 0, width: 760, height: 480)
        wideView.layoutSubtreeIfNeeded()

        let narrowView = NSHostingView(rootView: TripAlbumView(
            tripID: tripID,
            events: events,
            calendar: calendar,
            open: { _ in }
        ))
        narrowView.frame = CGRect(x: 0, y: 0, width: 500, height: 480)
        narrowView.layoutSubtreeIfNeeded()

        XCTAssertNotNil(wideView.hitTest(CGPoint(x: 380, y: 240)))
        XCTAssertNotNil(narrowView.hitTest(CGPoint(x: 250, y: 240)))
    }

    func testAlbumPostcardDestinationRoutesToTheExactCardEvent() {
        let event = event(id: UUID(), tripID: UUID(), at: 0)

        XCTAssertEqual(TripAlbumView.postcardDestination(for: event), .postcard(event.id))
    }

    @MainActor
    func testAlbumInitializerAcceptsDeterministicCalendarWithoutBreakingExistingCallSite() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tripID = UUID()

        _ = TripAlbumView(tripID: tripID, events: [], calendar: calendar) { _ in }
        _ = TripAlbumView(tripID: tripID, events: []) { _ in }
    }

    func testAlbumSourceRendersNonStickyDateGroupsWithAccessibleNativeHeadings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/TravelViews.swift"))
        let albumStart = try XCTUnwrap(source.range(of: "@MainActor\npublic struct TripAlbumView: View"))
        let albumEnd = try XCTUnwrap(source.range(of: "public struct TripAlbumGeometry"))
        let albumSource = String(source[albumStart.lowerBound..<albumEnd.lowerBound])

        XCTAssertTrue(albumSource.contains("TripAlbumDateGrouping.groups(orderedEvents: ordered, calendar: calendar)"))
        XCTAssertTrue(albumSource.contains("TripAlbumDateGrouping.visibleLabel"))
        XCTAssertTrue(albumSource.contains("TripAlbumDateGrouping.accessibilityLabel"))
        XCTAssertTrue(albumSource.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertTrue(albumSource.contains("Rectangle().fill(.secondary.opacity(0.18)).frame(height: 1)"))
        XCTAssertTrue(albumSource.contains("Button { open(Self.postcardDestination(for: event)) }"))
        XCTAssertTrue(albumSource.contains("LazyVStack(alignment: .leading, spacing: TripAlbumLayout.dateGroupSpacing)"))
        XCTAssertTrue(albumSource.contains("GeometryReader { proxy in\n                    ScrollView {"))
        XCTAssertTrue(albumSource.contains("TripAlbumLayout.minimumContentHeight("))
        XCTAssertTrue(albumSource.contains("dateGroupCount: groups.count"))
        XCTAssertEqual(albumSource.components(separatedBy: "TripAlbumLayout.geometry(").count - 1, 1)
        XCTAssertFalse(albumSource.contains("pinnedViews"))
    }

    @MainActor
    func testPostcardArtworkConstructsInDetailAndCompactProfiles() {
        let location = Location(country: "日本", city: "上高地", place: "河童桥")
        let event = postcardEvent(
            location: location,
            quote: "风从梓川吹过来，今天的心也变得很轻。"
        )
        let detail = NSHostingView(rootView: PostcardArtworkView(
            event: event, rootURL: nil, height: 230, profile: .detail
        ))
        let compact = NSHostingView(rootView: PostcardArtworkView(
            event: event, rootURL: nil, height: 100, profile: .compact
        ))
        detail.frame = CGRect(x: 0, y: 0, width: 360, height: 230)
        compact.frame = CGRect(x: 0, y: 0, width: 170, height: 100)

        detail.layoutSubtreeIfNeeded()
        compact.layoutSubtreeIfNeeded()

        XCTAssertNotNil(detail.hitTest(CGPoint(x: 180, y: 115)))
        XCTAssertNotNil(compact.hitTest(CGPoint(x: 85, y: 50)))
        XCTAssertEqual(
            PostcardArtworkView.accessibilityText(event: event),
            "日本 · 上高地 · 河童桥。风从梓川吹过来，今天的心也变得很轻。"
        )
    }

    @MainActor
    func testPreviewBlackCatOverlayRendersThePackagedPixelSprite() throws {
        let assetURL = try XCTUnwrap(
            TravelAlbumPreviewCatalog.catResourceURL(
                for: .sitting,
                in: TravelUIResources.bundle
            )
        )
        let size = CGSize(width: 360, height: 230)
        let placement = try XCTUnwrap(TravelAlbumPreviewCatalog.definitions.first?.catPlacement)
        let descriptor = PreviewBlackCatOverlayDescriptor(
            assetURL: assetURL,
            placement: placement
        )
        let renderer = ImageRenderer(content: PreviewBlackCatOverlay(
            descriptor: descriptor,
            containerSize: size,
            profile: .detail
        ).frame(width: size.width, height: size.height))
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var visiblePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.05 {
                visiblePixels += 1
            }
        }
        XCTAssertGreaterThan(visiblePixels, 300)
    }

    @MainActor
    func testOrdinaryPostcardRootDoesNotResolvePreviewCat() throws {
        let event = TripEvent(
            id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .exploring,
            location: Location(country: "日本", city: "镰仓", place: "由比滨"), transport: nil,
            summary: "潮声里的镰仓。",
            mood: Mood(level: 2, label: "轻快", quote: "潮声把心事吹轻了。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready,
            postcardRelativePath: "postcards/trip/preview-kamakura-coast.png"
        )
        let ordinaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ordinary-travel-data-\(UUID().uuidString)", isDirectory: true)
        let catRoot = ordinaryRoot.appendingPathComponent("preview-cat", isDirectory: true)
        try FileManager.default.createDirectory(at: catRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ordinaryRoot) }
        let sourceCatURL = try XCTUnwrap(
            TravelAlbumPreviewCatalog.catResourceURL(for: .sitting, in: TravelUIResources.bundle)
        )
        try FileManager.default.copyItem(
            at: sourceCatURL,
            to: catRoot.appendingPathComponent(PreviewBlackCatPose.sitting.assetFilename)
        )

        XCTAssertNil(PostcardArtworkView.previewCatDescriptor(
            event: event,
            rootURL: ordinaryRoot
        ))
    }

    @MainActor
    func testAccessibilityUsesFullTrimmedLocationWhileArtworkUsesShortAlias() {
        let event = postcardEvent(
            location: Location(
                country: " Japan ",
                city: "\nOtsu",
                place: " Otsu Port old pier\t"
            ),
            quote: "The lake is bright."
        )

        XCTAssertEqual(PostcardArtworkMetadata(event: event).locationLabel, "大津港旧栈桥")
        XCTAssertEqual(
            PostcardArtworkView.accessibilityText(event: event),
            "Japan · Otsu · Otsu Port old pier。The lake is bright."
        )

        let hiddenVisual = PostcardOverlaySolver.unknownFallback(
            message: event.mood.quote,
            profile: .detail,
            containerSize: CGSize(width: 520, height: 230)
        )
        XCTAssertFalse(hiddenVisual.showsLocationLabel)
        XCTAssertEqual(
            PostcardArtworkView.accessibilityText(event: event),
            "Japan · Otsu · Otsu Port old pier。The lake is bright."
        )
    }

    @MainActor
    func testHistoricalLongQuoteUsesCompleteNormalizedVisualMessageAndRawAccessibility() {
        let fullQuote = "旅旅\r\n途途\u{2028}猫猫  " + String(repeating: "旅", count: 80)
        let event = postcardEvent(
            location: Location(country: "日本", city: "宫岛", place: "严岛神社"),
            quote: fullQuote
        )
        let metadata = PostcardArtworkMetadata(event: event)

        XCTAssertEqual(metadata.fullMessage, fullQuote)
        XCTAssertEqual(metadata.visualMessage, "旅旅 途途 猫猫 " + String(repeating: "旅", count: 80))
        XCTAssertEqual(
            PostcardArtworkView.accessibilityText(event: event),
            "日本 · 宫岛 · 严岛神社。\(fullQuote)"
        )
    }

    func testAspectFillTransformMapsWideImageThroughHorizontalCrop() {
        let transform = PostcardAspectFillTransform(
            imageSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(transform.displayRect(forImageNormalized: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(transform.displayRect(forImageNormalized: CGRect(x: 0, y: 0, width: 0.25, height: 1)), .zero)
    }

    func testAspectFillTransformMapsPortraitImageThroughVerticalCrop() {
        let transform = PostcardAspectFillTransform(
            imageSize: CGSize(width: 200, height: 400),
            containerSize: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(transform.displayRect(forImageNormalized: CGRect(x: 0, y: 0.25, width: 1, height: 0.5)), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(transform.displayRect(forImageNormalized: CGRect(x: 0, y: 0, width: 1, height: 0.25)), .zero)
    }

    func testArtworkLoadIdentityRejectsStaleResult() {
        XCTAssertTrue(PostcardArtworkLoadIdentity.shouldPublish(requestID: "new", currentID: "new"))
        XCTAssertFalse(PostcardArtworkLoadIdentity.shouldPublish(requestID: "old", currentID: "new"))
    }

    func testPostcardAnalysisCachePolicyMatchesImageCacheBound() {
        XCTAssertEqual(PostcardAnalysisCachePolicy.maximumItemCount, 8)
        XCTAssertEqual(PostcardAnalysisCachePolicy.maximumItemCount, PostcardImageCachePolicy.maximumItemCount)
    }

    func testCompactArtworkReservesEnoughHeightForTwoMoodLines() {
        let rect = PostcardOverlayGeometry.rect(for: .bottomLeading, profile: .compact)

        XCTAssertGreaterThanOrEqual(rect.height, 0.36)
        XCTAssertLessThanOrEqual(rect.maxY, 0.96)
    }

    func testCompactArtworkAllowsFullDestinationToWrap() {
        XCTAssertEqual(PostcardOverlayGeometry.locationLineLimit(profile: .compact), 2)
        XCTAssertGreaterThanOrEqual(
            PostcardOverlayGeometry.rect(for: .topLeading, profile: .compact).height,
            0.21
        )
    }

    func testFocusedViewsExposeOnlyTheRequiredNextRoute() {
        let eventID = UUID()
        let tripID = UUID()

        XCTAssertEqual(PetHomeView.destination, .status)
        XCTAssertEqual(AwayTagView.destination, .status)
        XCTAssertEqual(StatusBubbleView.destination(unreadPostcardID: eventID, base: .pet), .postcard(eventID))
        XCTAssertEqual(StatusBubbleView.destination(unreadPostcardID: nil, base: .awayTag), .awayTag)
        XCTAssertEqual(PostcardView.albumDestination(tripID: tripID), .album(tripID))
    }

    func testStatusBubbleActionLabelUsesUnreadCopyOrConfiguredEmptyCopy() {
        XCTAssertEqual(
            StatusBubbleView.actionLabel(unreadPostcardID: UUID(), emptyActionLabel: "关闭窗口"),
            "打开新明信片"
        )
        XCTAssertEqual(
            StatusBubbleView.actionLabel(unreadPostcardID: nil, emptyActionLabel: "关闭窗口"),
            "关闭窗口"
        )
        XCTAssertEqual(
            StatusBubbleView.actionLabel(unreadPostcardID: nil, emptyActionLabel: "返回小猫"),
            "返回小猫"
        )
    }

    func testStatusNarrativeUsesBoundedScrollingSoActionsRemainReachable() {
        XCTAssertTrue(StatusBubbleLayoutPolicy.usesScrollableNarrative)
        XCTAssertGreaterThan(StatusBubbleLayoutPolicy.maximumNarrativeHeight, 0)
        XCTAssertLessThanOrEqual(StatusBubbleLayoutPolicy.maximumNarrativeHeight, 220)
    }

    func testStatusDetailNarrativeKeepsFullPersistedMoodQuoteSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/TravelUI/TravelViews.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("model.snapshot.openHook ?? model.snapshot.mood.quote"))
    }

    @MainActor
    func testStatusBubbleConstructsAtPanelSizeWithVeryLongNarrative() {
        let view = StatusBubbleView(
            text: String(repeating: "小猫沿着海岸慢慢旅行。", count: 500),
            mood: String(repeating: "非常开心，想把一路的故事都告诉你。", count: 100),
            unreadPostcardID: UUID(),
            albumAvailable: true,
            openAlbum: {},
            open: { _ in }
        )
        .frame(width: 320, height: 360)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: 360)

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostingView.frame.size, CGSize(width: 320, height: 360))
        XCTAssertNotNil(hostingView.hitTest(CGPoint(x: 160, y: 180)))
    }

    func testBundledSuppliesMatchTheApprovedCatalogExactly() throws {
        let supplies = try SupplyCatalog.load()
        XCTAssertEqual(supplies, [
            Supply(id: "matcha-cookie", name: "抹茶饼干", influence: "分享、店铺或味觉体验"),
            Supply(id: "camera", name: "小相机", influence: "风景事件和自拍"),
            Supply(id: "blanket", name: "小毯子", influence: "安静、露营或夜晚场景"),
            Supply(id: "ticket-case", name: "车票夹", influence: "铁路和旧车站"),
            Supply(id: "raincoat", name: "小雨衣", influence: "雨天的积极事件"),
        ])
        XCTAssertEqual(Set(supplies.map(\.id)).count, supplies.count)
    }

    func testAlbumShowsOnlyArrivedPostcardsFromRequestedTrip() {
        let currentTrip = UUID()
        let otherTrip = UUID()
        let past = event(id: UUID(), tripID: currentTrip, at: 20)
        let future = event(id: UUID(), tripID: currentTrip, at: 40)
        let other = event(id: UUID(), tripID: otherTrip, at: 10)

        XCTAssertEqual(
            TripAlbumView.orderedEvents(
                tripID: currentTrip,
                events: [future, other, past],
                now: Date(timeIntervalSince1970: 30)
            ).map(\.id),
            [past.id]
        )
    }

    func testPostcardImageLoaderRejectsTraversalSymlinksAndAcceptsContainedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("postcards/trip/card.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: image)
        let unrelated = root.appendingPathComponent("unrelated.png")
        try Data([0]).write(to: unrelated)

        XCTAssertEqual(try PostcardImageLoader.loadData(relativePath: "postcards/trip/card.png", rootURL: root), Data([0]))
        XCTAssertThrowsError(try PostcardImageLoader.loadData(relativePath: "../secret.png", rootURL: root))
        XCTAssertThrowsError(try PostcardImageLoader.loadData(relativePath: image.path, rootURL: root))

        let outside = root.appendingPathComponent("outside.png")
        try Data([1]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("postcards/trip/link.png"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try PostcardImageLoader.loadData(relativePath: "postcards/trip/link.png", rootURL: root))

        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data([2]).write(to: outsideDirectory.appendingPathComponent("nested.png"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("postcards/linked-dir"),
            withDestinationURL: outsideDirectory
        )
        XCTAssertThrowsError(try PostcardImageLoader.loadData(relativePath: "postcards/linked-dir/nested.png", rootURL: root))
    }

    func testPostcardImageLoaderEnforcesSizeBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let postcards = root.appendingPathComponent("postcards")
        try FileManager.default.createDirectory(at: postcards, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: postcards.appendingPathComponent("trip"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: postcards.appendingPathComponent("trip/large.png"))
        XCTAssertThrowsError(try PostcardImageLoader.loadData(relativePath: "postcards/trip/large.png", rootURL: root, maximumBytes: 4))
    }

    func testPostcardImageLoaderAcceptsSafeBaselineLegacyReadyPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("postcards/trip-1/foo.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected = Data([4, 5, 6])
        try expected.write(to: image)

        XCTAssertEqual(try PostcardImageLoader.loadData(relativePath: "trip-1/foo.png", rootURL: root), expected)
    }

    func testRepositoryReadyPathLoadsThroughPostcardImageLoader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let repository = try TravelRepository(root: root, clock: FixedClock(now: now))
        let tripID = UUID()
        let eventID = UUID()
        let mood = Mood(level: 1, label: "好奇", quote: "看看风景。")
        let event = TripEvent(
            id: eventID, tripID: tripID, previousEventID: nil, occurredAt: now,
            phase: .preparing, location: nil, transport: nil, summary: "寄出明信片。",
            mood: mood, continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .pendingImage, postcardRelativePath: nil
        )
        try repository.publish(event: event, next: TripSnapshot(
            stateVersion: 1, tripID: tripID, lastEventID: eventID, phase: .preparing,
            nextActionAt: now.addingTimeInterval(60), lastUpdatedAt: now,
            usedItemIDs: [], visitedPlaces: [], mood: mood
        ))
        let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let expected = try pngData(width: 768, height: 768)
        let relativePath = "postcards/\(tripID.uuidString.lowercased())/card.png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relativePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try expected.write(to: root.appendingPathComponent(relativePath))
        _ = try repository.markImage(ImageResultEnvelope(
            eventId: eventID, status: .ready, attemptedAt: now, relativePath: relativePath,
            reason: nil, attemptToken: work.attemptToken, attemptCount: work.imageAttemptCount,
            publishedNarrativeHash: work.publishedNarrativeHash
        ), mode: .fast)
        let path = try XCTUnwrap(repository.events().first?.postcardRelativePath)
        XCTAssertEqual(try PostcardImageLoader.loadData(relativePath: path, rootURL: root), expected)
    }

    func testPostcardImageDecoderRejectsAbsurdDimensionsBeforeDecode() {
        XCTAssertThrowsError(
            try PostcardImageDecoder.validateDimensions(width: 100_000, height: 100_000)
        ) { error in
            XCTAssertEqual(error as? PostcardImageDecoderError, .absurdDimensions)
        }
    }

    func testPostcardImageDecoderCreatesBoundedThumbnailForHighResolutionImage() throws {
        let decoded = try PostcardImageDecoder.decodeThumbnail(
            data: pngData(width: 2_048, height: 1_280)
        )

        XCTAssertLessThanOrEqual(decoded.width, PostcardImageDecoder.maximumPixelSize)
        XCTAssertLessThanOrEqual(decoded.height, PostcardImageDecoder.maximumPixelSize)
        XCTAssertGreaterThan(decoded.width, 0)
        XCTAssertGreaterThan(decoded.height, 0)
    }

    func testPostcardImageDecoderAcceptsOrdinaryImage() throws {
        let decoded = try PostcardImageDecoder.decodeThumbnail(data: pngData(width: 32, height: 20))

        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 20)
    }

    func testPostcardImageCachePolicyBoundsEightRetinaThumbnails() {
        XCTAssertEqual(PostcardImageCachePolicy.maximumItemCount, 8)
        XCTAssertEqual(
            PostcardImageCachePolicy.maximumDecodedBytes,
            1_024 * 1_024 * 4 * 8
        )
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func event(
        id: UUID,
        tripID: UUID,
        at: TimeInterval,
        summary: String = "旅途"
    ) -> TripEvent {
        TripEvent(
            id: id, tripID: tripID, previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: at), phase: .exploring,
            location: nil, transport: nil, summary: summary,
            mood: Mood(level: 1, label: "平静", quote: "慢慢走。"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: nil
        )
    }

    private func postcardEvent(location: Location, quote: String) -> TripEvent {
        postcardEvent(
            location: location,
            mood: Mood(level: 2, label: "轻快", quote: quote)
        )
    }

    private func postcardEvent(location: Location?, mood: Mood) -> TripEvent {
        TripEvent(
            id: UUID(), tripID: UUID(), previousEventID: nil,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .exploring,
            location: location, transport: nil, summary: "梓川边的风景。",
            mood: mood,
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .ready, postcardRelativePath: "postcards/trip/card.png"
        )
    }
}

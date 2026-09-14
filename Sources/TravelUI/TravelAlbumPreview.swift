import CoreGraphics
import Foundation
import TravelCore

public enum PreviewBlackCatPose: String, CaseIterable, Sendable {
    case front
    case side
    case sitting

    public var assetFilename: String { "preview-cat-\(rawValue).png" }
}

public struct PreviewBlackCatPlacement: Equatable, Sendable {
    public static let authorizedSourceAspectRatio: CGFloat = 192.0 / 208.0

    public let pose: PreviewBlackCatPose
    public let anchor: CGPoint
    public let heightFraction: CGFloat
    public let isMirrored: Bool

    public init(
        pose: PreviewBlackCatPose,
        anchor: CGPoint,
        heightFraction: CGFloat,
        isMirrored: Bool
    ) {
        self.pose = pose
        self.anchor = anchor
        self.heightFraction = heightFraction
        self.isMirrored = isMirrored
    }

    public var isValid: Bool {
        let widthFraction = heightFraction * Self.authorizedSourceAspectRatio
        return anchor.x.isFinite
            && anchor.y.isFinite
            && heightFraction.isFinite
            && (0.46...0.60).contains(heightFraction)
            && anchor.x - widthFraction / 2 >= 0
            && anchor.x + widthFraction / 2 <= 1
            && anchor.y - heightFraction >= 0
            && anchor.y <= 1
    }

    public func frame(in size: CGSize, sourceAspectRatio: CGFloat) -> CGRect {
        guard size.width > 0,
              size.height > 0,
              sourceAspectRatio.isFinite,
              sourceAspectRatio > 0 else { return .zero }
        let height = size.height * heightFraction
        let width = height * sourceAspectRatio
        return CGRect(
            x: size.width * anchor.x - width / 2,
            y: size.height * anchor.y - height,
            width: width,
            height: height
        )
    }
}

public struct PreviewBlackCatOverlayDescriptor: Equatable, Sendable {
    public let assetURL: URL
    public let placement: PreviewBlackCatPlacement

    public init(assetURL: URL, placement: PreviewBlackCatPlacement) {
        self.assetURL = assetURL
        self.placement = placement
    }
}

public struct TravelAlbumPreviewDefinition: Equatable, Sendable {
    public let filename: String
    public let location: Location
    public let summary: String
    public let mood: Mood
    public let catPlacement: PreviewBlackCatPlacement

    public init(
        filename: String,
        location: Location,
        summary: String,
        mood: Mood,
        catPlacement: PreviewBlackCatPlacement
    ) {
        self.filename = filename
        self.location = location
        self.summary = summary
        self.mood = mood
        self.catPlacement = catPlacement
    }
}

public enum TravelAlbumPreviewCatalog {
    public static let directory = "PreviewPostcards"
    public static let catDirectory = "PreviewBlackCat"

    public static let definitions: [TravelAlbumPreviewDefinition] = [
        TravelAlbumPreviewDefinition(
            filename: "preview-kamakura-coast.png",
            location: Location(country: "日本", city: "镰仓", place: "由比滨"),
            summary: "黑猫沿着海岸散步，把清晨的潮声收进了明信片。",
            mood: Mood(level: 1, label: "轻快", quote: "潮声把心事吹轻了。"),
            catPlacement: PreviewBlackCatPlacement(
                pose: .sitting,
                anchor: CGPoint(x: 0.24, y: 0.94),
                heightFraction: 0.46,
                isMirrored: false
            )
        ),
        TravelAlbumPreviewDefinition(
            filename: "preview-kyoto-lanterns.png",
            location: Location(country: "日本", city: "京都", place: "八坂小路"),
            summary: "灯笼渐次亮起，黑猫在古街转角停下脚步。",
            mood: Mood(level: 2, label: "温暖", quote: "灯笼一盏盏亮起来，像有人在等我。"),
            catPlacement: PreviewBlackCatPlacement(
                pose: .side,
                anchor: CGPoint(x: 0.69, y: 0.96),
                heightFraction: 0.52,
                isMirrored: true
            )
        ),
        TravelAlbumPreviewDefinition(
            filename: "preview-dali-lake.png",
            location: Location(country: "中国", city: "大理", place: "洱海"),
            summary: "云影掠过湖面，黑猫在风里安静看了很久。",
            mood: Mood(level: 0, label: "松弛", quote: "云很低，风很慢。"),
            catPlacement: PreviewBlackCatPlacement(
                pose: .sitting,
                anchor: CGPoint(x: 0.75, y: 0.94),
                heightFraction: 0.46,
                isMirrored: false
            )
        ),
        TravelAlbumPreviewDefinition(
            filename: "preview-iceland-aurora.png",
            location: Location(country: "冰岛", city: "雷克雅未克", place: "极光原野"),
            summary: "极光越过雪原，黑猫第一次觉得夜晚也会写信。",
            mood: Mood(level: 3, label: "惊喜", quote: "极光替夜晚写了一封长信。"),
            catPlacement: PreviewBlackCatPlacement(
                pose: .sitting,
                anchor: CGPoint(x: 0.25, y: 0.94),
                heightFraction: 0.46,
                isMirrored: false
            )
        ),
        TravelAlbumPreviewDefinition(
            filename: "preview-hangzhou-garden.png",
            location: Location(country: "中国", city: "杭州", place: "曲院风荷"),
            summary: "雨后的荷叶滴答作响，黑猫绕着池边慢慢走。",
            mood: Mood(level: 1, label: "清新", quote: "雨停后，荷叶还在滴答作响。"),
            catPlacement: PreviewBlackCatPlacement(
                pose: .side,
                anchor: CGPoint(x: 0.31, y: 0.96),
                heightFraction: 0.60,
                isMirrored: false
            )
        ),
        TravelAlbumPreviewDefinition(
            filename: "preview-paris-dusk.png",
            location: Location(country: "法国", city: "巴黎", place: "蒙马特"),
            summary: "暮色落在屋顶上，黑猫回头记住了这段粉色天光。",
            mood: Mood(level: -1, label: "眷恋", quote: "今天有一点想家，也有一点舍不得走。"),
            catPlacement: PreviewBlackCatPlacement(
                pose: .front,
                anchor: CGPoint(x: 0.74, y: 0.95),
                heightFraction: 0.50,
                isMirrored: false
            )
        ),
    ]

    public static func resourceURL(
        for definition: TravelAlbumPreviewDefinition,
        in bundle: Bundle
    ) -> URL? {
        let parts = definition.filename.split(separator: ".", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let fileExtension = parts.count > 1 ? parts[1] : nil
        return bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: directory
        ) ?? bundle.url(forResource: name, withExtension: fileExtension)
    }

    public static func catResourceURL(
        for pose: PreviewBlackCatPose,
        in bundle: Bundle
    ) -> URL? {
        let name = "preview-cat-\(pose.rawValue)"
        return bundle.url(
            forResource: name,
            withExtension: "png",
            subdirectory: catDirectory
        ) ?? bundle.url(forResource: name, withExtension: "png")
    }

    public static func overlayDescriptor(
        event: TripEvent,
        rootURL: URL?
    ) -> PreviewBlackCatOverlayDescriptor? {
        guard let rootURL,
              TravelAlbumPreviewFactory.isSafePreviewRoot(rootURL),
              let relativePath = event.postcardRelativePath,
              let filename = relativePath.split(separator: "/").last.map(String.init),
              let definition = definitions.first(where: { $0.filename == filename }),
              definition.catPlacement.isValid else { return nil }
        let assetURL = rootURL
            .appendingPathComponent("preview-cat", isDirectory: true)
            .appendingPathComponent(definition.catPlacement.pose.assetFilename)
        guard let values = try? assetURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return PreviewBlackCatOverlayDescriptor(
            assetURL: assetURL,
            placement: definition.catPlacement
        )
    }
}

public enum TravelAlbumPreviewError: LocalizedError, Equatable {
    case incompleteAssets
    case invalidAsset(String)
    case invalidCatPlacement
    case unsafeTemporaryRoot

    public var errorDescription: String? {
        switch self {
        case .incompleteAssets:
            return "测试样片不完整，请重新安装 Travel Cat。"
        case let .invalidAsset(name):
            return "测试样片无法读取：\(name)"
        case .invalidCatPlacement:
            return "测试黑猫位置配置无效。"
        case .unsafeTemporaryRoot:
            return "无法安全准备测试旅行册目录。"
        }
    }
}

public enum TravelAlbumPreviewFactory {
    public static let previewRootPrefix = "travel-cat-preview-"

    static func previewEventDates(now: Date, calendar: Calendar) throws -> [Date] {
        let schedule: [(dayOffset: Int, minuteOffset: Int)] = [
            (-3, 0),
            (-3, 30),
            (-2, 0),
            (-1, 0),
            (-1, 30),
            (-1, 60),
        ]
        guard schedule.count == TravelAlbumPreviewCatalog.definitions.count else {
            throw TravelAlbumPreviewError.incompleteAssets
        }

        let previewDay = calendar.startOfDay(for: now)

        return try schedule.map { timing in
            guard let day = calendar.date(
                byAdding: .day,
                value: timing.dayOffset,
                to: previewDay
            ), let start = calendar.date(
                bySettingHour: 10,
                minute: 0,
                second: 0,
                of: day
            ), let occurredAt = calendar.date(
                byAdding: .minute,
                value: timing.minuteOffset,
                to: start
            ) else {
                throw TravelAlbumPreviewError.incompleteAssets
            }
            return occurredAt
        }
    }

    @MainActor
    public static func make(
        temporaryDirectory: URL,
        resourceURLs: [URL],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> TravelAlbumPreviewSession {
        let bundledCatURLs = PreviewBlackCatPose.allCases.compactMap {
            TravelAlbumPreviewCatalog.catResourceURL(for: $0, in: TravelUIResources.bundle)
        }
        return try make(
            temporaryDirectory: temporaryDirectory,
            resourceURLs: resourceURLs,
            catResourceURLs: bundledCatURLs,
            now: now,
            calendar: calendar
        )
    }

    @MainActor
    public static func make(
        temporaryDirectory: URL,
        resourceURLs: [URL],
        catResourceURLs: [URL],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> TravelAlbumPreviewSession {
        guard temporaryDirectory.hasDirectoryPath,
              isSafeTemporaryParent(temporaryDirectory)
        else {
            throw TravelAlbumPreviewError.unsafeTemporaryRoot
        }

        let tripID = UUID()
        let rootURL = temporaryDirectory
            .appendingPathComponent("\(previewRootPrefix)\(UUID().uuidString)", isDirectory: true)
        let postcardRoot = rootURL
            .appendingPathComponent("postcards", isDirectory: true)
            .appendingPathComponent(tripID.uuidString, isDirectory: true)

        func cleanupFolder() {
            if isSafePreviewRoot(rootURL) {
                try? FileManager.default.removeItem(at: rootURL)
            }
        }

        do {
            try FileManager.default.createDirectory(at: postcardRoot, withIntermediateDirectories: true)
            guard resourceURLs.count == TravelAlbumPreviewCatalog.definitions.count else {
                throw TravelAlbumPreviewError.incompleteAssets
            }
            guard TravelAlbumPreviewCatalog.definitions.allSatisfy({ $0.catPlacement.isValid }) else {
                throw TravelAlbumPreviewError.invalidCatPlacement
            }
            guard catResourceURLs.count == PreviewBlackCatPose.allCases.count else {
                throw TravelAlbumPreviewError.incompleteAssets
            }

            let catRoot = rootURL.appendingPathComponent("preview-cat", isDirectory: true)
            try FileManager.default.createDirectory(at: catRoot, withIntermediateDirectories: true)
            for (pose, sourceURL) in zip(PreviewBlackCatPose.allCases, catResourceURLs) {
                guard sourceURL.lastPathComponent == pose.assetFilename else {
                    throw TravelAlbumPreviewError.invalidAsset(sourceURL.lastPathComponent)
                }
                let sourceData = try Data(contentsOf: sourceURL)
                let sourceImage = try PostcardImageDecoder.decodeThumbnail(data: sourceData)
                guard sourceImage.width > 0, sourceImage.height > 0 else {
                    throw TravelAlbumPreviewError.invalidAsset(pose.assetFilename)
                }
                try sourceData.write(
                    to: catRoot.appendingPathComponent(pose.assetFilename),
                    options: .atomic
                )
            }

            for (definition, sourceURL) in zip(TravelAlbumPreviewCatalog.definitions, resourceURLs) {
                guard definition.filename == sourceURL.lastPathComponent else {
                    throw TravelAlbumPreviewError.invalidAsset(sourceURL.lastPathComponent)
                }

                let sourceData = try Data(contentsOf: sourceURL)
                let sourceImage = try PostcardImageDecoder.decodeThumbnail(data: sourceData)
                guard sourceImage.width > sourceImage.height else {
                    throw TravelAlbumPreviewError.invalidAsset(definition.filename)
                }

                let destinationURL = postcardRoot.appendingPathComponent(definition.filename)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

                let relativePath = "postcards/\(tripID.uuidString)/\(definition.filename)"
                let loaded = try PostcardImageLoader.loadData(relativePath: relativePath, rootURL: rootURL)
                guard !loaded.isEmpty else {
                    throw TravelAlbumPreviewError.invalidAsset(definition.filename)
                }
            }

            var snapshot = TripSnapshot(
                schemaVersion: 1,
                stateVersion: 1,
                tripID: tripID,
                lastEventID: nil,
                phase: .exploring,
                nextActionAt: now.addingTimeInterval(120),
                lastUpdatedAt: now,
                usedItemIDs: [],
                visitedPlaces: TravelAlbumPreviewCatalog.definitions.map { $0.location.city },
                mood: Mood(level: 0, label: "平静", quote: "准备出发去看看世界。")
            )

            var events: [TripEvent] = []
            var previousID: UUID?
            let eventDates = try previewEventDates(now: now, calendar: calendar)
            guard eventDates.count == TravelAlbumPreviewCatalog.definitions.count else {
                throw TravelAlbumPreviewError.incompleteAssets
            }

            for (offset, definition) in TravelAlbumPreviewCatalog.definitions.enumerated() {
                let occurredAt = eventDates[offset]
                let eventID = UUID()
                let event = TripEvent(
                    id: eventID,
                    tripID: tripID,
                    previousEventID: previousID,
                    occurredAt: occurredAt,
                    phase: .exploring,
                    location: definition.location,
                    transport: nil,
                    summary: definition.summary,
                    mood: definition.mood,
                    continuityReferences: [],
                    openHook: nil,
                    consumedItemID: nil,
                    postcardStatus: .ready,
                    postcardRelativePath: "postcards/\(tripID.uuidString)/\(definition.filename)"
                )
                events.append(event)
                previousID = eventID
            }
            snapshot.lastEventID = events.last?.id

            let suiteName = "com.travelcat.preview-session.\(tripID.uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw TravelAlbumPreviewError.incompleteAssets
            }

            let model = AppModel(
                snapshot: snapshot,
                events: events,
                dataRoot: rootURL,
                defaults: defaults
            )
            guard model.openAlbumFromPrompt(tripID: tripID) else {
                throw TravelAlbumPreviewError.incompleteAssets
            }

            return TravelAlbumPreviewSession(
                rootURL: rootURL,
                tripID: tripID,
                events: events,
                model: model,
                cleanup: {
                    defaults.removePersistentDomain(forName: suiteName)
                    cleanupFolder()
                }
            )
        } catch {
            cleanupFolder()
            throw error
        }
    }

    static func isSafePreviewRoot(_ rootURL: URL) -> Bool {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let tempPath = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return rootPath.hasPrefix(tempPath + "/")
            && rootURL.standardizedFileURL.lastPathComponent.hasPrefix(previewRootPrefix)
    }

    private static func isSafeTemporaryParent(_ parentURL: URL) -> Bool {
        guard parentURL.isFileURL,
              let values = try? parentURL.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true
        else { return false }

        let parentPath = parentURL.resolvingSymlinksInPath().standardizedFileURL.path
        let tempPath = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return parentPath == tempPath || parentPath.hasPrefix(tempPath + "/")
    }
}

public final class TravelAlbumPreviewSession {
    public let rootURL: URL
    public let tripID: UUID
    public let events: [TripEvent]
    public let model: AppModel
    private let cleanup: () -> Void
    private var isCleaned = false

    init(rootURL: URL, tripID: UUID, events: [TripEvent], model: AppModel, cleanup: @escaping () -> Void) {
        self.rootURL = rootURL
        self.tripID = tripID
        self.events = events
        self.model = model
        self.cleanup = cleanup
    }

    deinit { cleanUp() }

    public func cleanUp() {
        guard !isCleaned else { return }
        isCleaned = true
        cleanup()
    }

    public func catAssetURL(for pose: PreviewBlackCatPose) -> URL? {
        let url = rootURL
            .appendingPathComponent("preview-cat", isDirectory: true)
            .appendingPathComponent(pose.assetFilename)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return url
    }
}

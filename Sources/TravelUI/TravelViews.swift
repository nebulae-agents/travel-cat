import AppKit
import Darwin
import Foundation
import ImageIO
import SwiftUI
import TravelCore

public struct Supply: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let influence: String

    public init(id: String, name: String, influence: String) {
        self.id = id
        self.name = name
        self.influence = influence
    }
}

public enum SupplyCatalog {
    public static func load() throws -> [Supply] {
        guard let url = TravelUIResources.bundle.url(forResource: "supplies", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let supplies = try JSONDecoder().decode([Supply].self, from: Data(contentsOf: url))
        guard Set(supplies.map(\.id)).count == supplies.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return supplies
    }

    public static func loadOrEmpty() -> [Supply] {
        (try? load()) ?? []
    }
}

public enum PostcardImageLoaderError: Error, Equatable, Sendable {
    case invalidPath
    case unsafeComponent
    case notRegularFile
    case tooLarge
    case ioFailure(Int32)
}

public enum PostcardImageLoader {
    public static let defaultMaximumBytes = 15 * 1_024 * 1_024

    public static func loadData(
        relativePath: String,
        rootURL: URL,
        maximumBytes: Int = defaultMaximumBytes
    ) throws -> Data {
        guard maximumBytes > 0,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/") else { throw PostcardImageLoaderError.invalidPath }
        let byteLimit = min(maximumBytes, defaultMaximumBytes)
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isCanonical = components.count == 3 && components.first == "postcards"
        let isLegacy = components.count == 2 && components.first != "postcards"
        guard isCanonical || isLegacy,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PostcardImageLoaderError.invalidPath
        }

        let canonicalRoot = rootURL.standardizedFileURL
        let rootDescriptor = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw PostcardImageLoaderError.ioFailure(errno) }
        var descriptors = [rootDescriptor]
        defer { descriptors.reversed().forEach { _ = close($0) } }

        var current = rootDescriptor
        let traversalComponents: [String]
        if isLegacy {
            let postcardsDescriptor = openat(rootDescriptor, "postcards", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard postcardsDescriptor >= 0 else { throw PostcardImageLoaderError.unsafeComponent }
            descriptors.append(postcardsDescriptor)
            current = postcardsDescriptor
            traversalComponents = components
        } else {
            traversalComponents = components
        }

        for component in traversalComponents.dropLast() {
            let descriptor = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw PostcardImageLoaderError.unsafeComponent }
            descriptors.append(descriptor)
            current = descriptor
        }

        guard let filename = traversalComponents.last else { throw PostcardImageLoaderError.invalidPath }
        let fileDescriptor = openat(current, filename, O_RDONLY | O_NOFOLLOW)
        guard fileDescriptor >= 0 else { throw PostcardImageLoaderError.unsafeComponent }
        descriptors.append(fileDescriptor)

        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { throw PostcardImageLoaderError.ioFailure(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw PostcardImageLoaderError.notRegularFile }
        guard info.st_size >= 0, info.st_size <= byteLimit else { throw PostcardImageLoaderError.tooLarge }

        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, byteLimit + 1))
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PostcardImageLoaderError.ioFailure(errno)
            }
            guard result.count + count <= byteLimit else { throw PostcardImageLoaderError.tooLarge }
            result.append(buffer, count: count)
        }
        return result
    }
}

public enum PostcardImageDecoderError: Error, Equatable, Sendable {
    case invalidImage
    case absurdDimensions
    case thumbnailCreationFailed
}

public enum PostcardImageDecoder {
    public static let maximumPixelSize = 1_024
    public static let maximumSourceDimension = 32_768
    public static let maximumSourcePixelCount: Int64 = 100_000_000

    public static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= maximumSourceDimension,
              height <= maximumSourceDimension,
              Int64(width) * Int64(height) <= maximumSourcePixelCount else {
            throw PostcardImageDecoderError.absurdDimensions
        }
    }

    public static func decodeThumbnail(
        data: Data,
        maximumPixelSize: Int = maximumPixelSize
    ) throws -> CGImage {
        try Task.checkCancellation()
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw PostcardImageDecoderError.invalidImage
        }
        try validateDimensions(width: width, height: height)
        try Task.checkCancellation()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximumPixelSize, Self.maximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PostcardImageDecoderError.thumbnailCreationFailed
        }
        try Task.checkCancellation()
        return thumbnail
    }
}

public enum PostcardImageCachePolicy {
    public static let maximumItemCount = 8
    public static let maximumDecodedBytes =
        PostcardImageDecoder.maximumPixelSize
        * PostcardImageDecoder.maximumPixelSize
        * 4
        * maximumItemCount
}

actor PostcardImageCache {
    static let shared = PostcardImageCache()
    private var values: [String: CGImage] = [:]
    private var order: [String] = []

    func image(relativePath: String, rootURL: URL) async throws -> CGImage {
        let key = rootURL.standardizedFileURL.path + "\u{0}" + relativePath
        if let value = values[key] { return value }
        try Task.checkCancellation()
        let task = Task.detached {
            try Task.checkCancellation()
            let data = try PostcardImageLoader.loadData(relativePath: relativePath, rootURL: rootURL)
            try Task.checkCancellation()
            return try PostcardImageDecoder.decodeThumbnail(data: data)
        }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        if order.count >= PostcardImageCachePolicy.maximumItemCount, let evicted = order.first {
            order.removeFirst()
            values.removeValue(forKey: evicted)
        }
        values[key] = value
        order.append(key)
        return value
    }
}

public enum StatusBubbleLayoutPolicy {
    public static let usesScrollableNarrative = true
    public static let maximumNarrativeHeight: CGFloat = 170
}

@MainActor
public struct StartupErrorView: View {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("旅行数据暂时无法读取").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(12)
    }
}

@MainActor
public struct PetHomeView: View {
    nonisolated public static let destination = PetPresentation.status

    private let phase: TravelPhase
    private let profile: CharacterProfile
    private let dataRoot: URL?
    private let open: (PetPresentation) -> Void

    public init(phase: TravelPhase, profile: CharacterProfile = .defaultBlackCat, dataRoot: URL? = nil, open: @escaping (PetPresentation) -> Void) {
        self.phase = phase
        self.profile = profile
        self.dataRoot = dataRoot
        self.open = open
    }

    public var body: some View {
        Button { open(Self.destination) } label: {
            PetSpriteView(state: phase, profile: profile, dataRoot: dataRoot)
                .padding(18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看宠物状态")
    }
}

@MainActor
public struct AwayTagView: View {
    nonisolated public static let destination = PetPresentation.status

    private let open: (PetPresentation) -> Void

    public init(open: @escaping (PetPresentation) -> Void) {
        self.open = open
    }

    public var body: some View {
        Button { open(Self.destination) } label: {
            VStack(spacing: 8) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 34, weight: .light))
                Text("宠物旅行中")
                    .font(.headline)
                Text("轻点看看它到哪里了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .rotationEffect(.degrees(-2))
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看旅行状态")
    }
}

@MainActor
public struct StatusBubbleView: View {
    private let text: String
    private let mood: String
    private let unreadPostcardID: UUID?
    private let base: PetPresentation
    private let open: (PetPresentation) -> Void
    private let albumAvailable: Bool
    private let openAlbum: () -> Void
    private let emptyActionLabel: String

    public init(
        text: String,
        mood: String,
        unreadPostcardID: UUID?,
        base: PetPresentation = .pet,
        albumAvailable: Bool = false,
        openAlbum: @escaping () -> Void = {},
        emptyActionLabel: String = "返回宠物",
        open: @escaping (PetPresentation) -> Void
    ) {
        self.text = text
        self.mood = mood
        self.unreadPostcardID = unreadPostcardID
        self.base = base
        self.albumAvailable = albumAvailable
        self.openAlbum = openAlbum
        self.emptyActionLabel = emptyActionLabel
        self.open = open
    }

    nonisolated public static func destination(
        unreadPostcardID: UUID?,
        base: PetPresentation
    ) -> PetPresentation {
        unreadPostcardID.map(PetPresentation.postcard) ?? base
    }

    nonisolated public static func actionLabel(
        unreadPostcardID: UUID?,
        emptyActionLabel: String
    ) -> String {
        unreadPostcardID == nil ? emptyActionLabel : "打开新明信片"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("旅途便笺").font(.headline)
                Spacer()
                Button { open(base) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text).multilineTextAlignment(.leading)
                    Text(mood).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: StatusBubbleLayoutPolicy.maximumNarrativeHeight)
            Button {
                open(Self.destination(unreadPostcardID: unreadPostcardID, base: base))
            } label: {
                Label(
                    Self.actionLabel(
                        unreadPostcardID: unreadPostcardID,
                        emptyActionLabel: emptyActionLabel
                    ),
                    systemImage: unreadPostcardID == nil ? "arrow.uturn.backward" : "envelope.badge"
                )
            }
            .buttonStyle(.borderedProminent)
            Button("旅行册", action: openAlbum)
                .buttonStyle(.bordered)
                .disabled(!albumAvailable)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(16)
    }
}

@MainActor
public struct PostcardView: View {
    private let event: TripEvent
    private let presentationReference: PostcardPresentationReference?
    private let rootURL: URL?
    private let open: (PetPresentation) -> Void
    private let back: PetPresentation

    public init(
        event: TripEvent,
        rootURL: URL? = nil,
        presentationReference: PostcardPresentationReference? = nil,
        back: PetPresentation = .status,
        open: @escaping (PetPresentation) -> Void
    ) {
        self.event = event
        self.presentationReference = presentationReference
        self.rootURL = rootURL
        self.back = back
        self.open = open
    }

    nonisolated public static func albumDestination(tripID: UUID) -> PetPresentation {
        .album(tripID)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { open(back) } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Text("POSTCARD").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PostcardArtworkView(event: event, rootURL: rootURL, height: 230, profile: .detail, presentationReference: presentationReference)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(PostcardDisplayLocation().resolveCompact(event.location))
                        .font(.title2.bold())
                        .accessibilityLabel(PostcardDisplayLocation().resolveSpoken(event.location))
                    Text(event.summary)
                    HStack {
                        Label(event.mood.label, systemImage: "sparkles")
                        Spacer()
                        Text(event.occurredAt, style: .date)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("打开旅行册") { open(Self.albumDestination(tripID: event.tripID)) }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
    }

}

@MainActor
public struct TripAlbumView: View {
    private let tripID: UUID
    private let events: [TripEvent]
    private let presentationReferences: [UUID: PostcardPresentationReference]
    private let rootURL: URL?
    private let calendar: Calendar
    private let now: Date
    private let open: (PetPresentation) -> Void

    public init(
        tripID: UUID,
        events: [TripEvent],
        rootURL: URL? = nil,
        presentationReferences: [UUID: PostcardPresentationReference] = [:],
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date(),
        open: @escaping (PetPresentation) -> Void
    ) {
        self.tripID = tripID
        self.events = events
        self.presentationReferences = presentationReferences
        self.rootURL = rootURL
        self.calendar = calendar
        self.now = now
        self.open = open
    }

    nonisolated public static func orderedEvents(
        tripID: UUID,
        events: [TripEvent],
        now: Date = Date()
    ) -> [TripEvent] {
        events.enumerated()
            .filter {
                let event = $0.element
                guard event.tripID == tripID, event.occurredAt <= now else { return false }
                switch event.postcardStatus {
                case .pendingImage, .ready, .imageUnavailable:
                    return true
                case .none, .rejected:
                    return false
                }
            }
            .sorted {
                if $0.element.occurredAt != $1.element.occurredAt {
                    return $0.element.occurredAt < $1.element.occurredAt
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    nonisolated static func postcardDestination(for event: TripEvent) -> PetPresentation {
        .postcard(event.id)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("旅行册").font(.title2.bold())
                Spacer()
                Button("关闭") { open(.status) }.buttonStyle(.plain)
            }
            let ordered = Self.orderedEvents(tripID: tripID, events: events, now: now)
            if ordered.isEmpty {
                ContentUnavailableView("还没有明信片", systemImage: "photo.stack")
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        let messages = ordered.map { PostcardArtworkMetadata(event: $0).visualMessage }
                        let groups = TripAlbumDateGrouping.groups(orderedEvents: ordered, calendar: calendar)
                        let showsYear = TripAlbumDateGrouping.spansMultipleYears(
                            days: groups.map(\.day),
                            calendar: calendar
                        )
                        let geometry = TripAlbumLayout.geometry(
                            availableWidth: proxy.size.width,
                            messages: messages
                        )
                        LazyVStack(alignment: .leading, spacing: TripAlbumLayout.dateGroupSpacing) {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: TripAlbumLayout.spacing) {
                                    HStack(spacing: TripAlbumLayout.spacing) {
                                        Text(
                                            TripAlbumDateGrouping.visibleLabel(
                                                for: group.day,
                                                showsYear: showsYear,
                                                calendar: calendar
                                            )
                                        )
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .accessibilityAddTraits(.isHeader)
                                        .accessibilityLabel(
                                            TripAlbumDateGrouping.accessibilityLabel(
                                                for: group.day,
                                                calendar: calendar
                                            )
                                        )
                                        Rectangle().fill(.secondary.opacity(0.18)).frame(height: 1)
                                    }

                                    LazyVGrid(
                                        columns: Array(
                                            repeating: GridItem(
                                                .flexible(minimum: geometry.artworkWidth),
                                                spacing: TripAlbumLayout.spacing
                                            ),
                                            count: geometry.columnCount
                                        ),
                                        spacing: TripAlbumLayout.spacing
                                    ) {
                                        ForEach(group.events) { event in
                                            Button { open(Self.postcardDestination(for: event)) } label: {
                                                AlbumCard(event: event, rootURL: rootURL, presentationReference: presentationReferences[event.id])
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: TripAlbumLayout.minimumContentHeight(
                            eventCount: ordered.count,
                            dateGroupCount: groups.count
                        ))
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(12)
    }
}

public struct TripAlbumGeometry: Equatable, Sendable {
    public let columnCount: Int
    public let artworkWidth: CGFloat
    public let isReadable: Bool
}

public enum TripAlbumLayout {
    public static let spacing: CGFloat = 12
    public static let dateGroupSpacing: CGFloat = 16
    public static let dateHeaderHeightContribution: CGFloat = 32
    public static let cardHorizontalPadding: CGFloat = 20
    public static let readableCompactArtworkWidth: CGFloat = 320
    public static let minimumWindowContentWidth: CGFloat = 760
    public static let artworkHeight: CGFloat = 120

    public static func minimumContentHeight(eventCount: Int, dateGroupCount: Int) -> CGFloat {
        CGFloat(max(eventCount, 0)) * 165
            + CGFloat(max(dateGroupCount, 0)) * dateHeaderHeightContribution
    }

    public static func geometry(
        availableWidth: CGFloat,
        messages: [String]
    ) -> TripAlbumGeometry {
        let actualWidth = max(availableWidth, 0)
        let twoColumnArtwork = (actualWidth - spacing) / 2 - cardHorizontalPadding
        let fitsOrdinaryMessages = messages.allSatisfy {
            PostcardOverlayTypography.fit(
                message: $0,
                region: .wideMiddleTrailing,
                profile: .compact,
                containerSize: CGSize(width: max(twoColumnArtwork, 1), height: artworkHeight)
            ).fitsVertically
        }
        if twoColumnArtwork >= readableCompactArtworkWidth, fitsOrdinaryMessages {
            return TripAlbumGeometry(columnCount: 2, artworkWidth: twoColumnArtwork, isReadable: true)
        }
        let singleArtwork = max(actualWidth - cardHorizontalPadding, 0)
        return TripAlbumGeometry(
            columnCount: 1,
            artworkWidth: singleArtwork,
            isReadable: singleArtwork >= readableCompactArtworkWidth
        )
    }
}

@MainActor
private struct AlbumCard: View {
    let event: TripEvent
    let rootURL: URL?
    var presentationReference: PostcardPresentationReference? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PostcardArtworkView(event: event, rootURL: rootURL, height: TripAlbumLayout.artworkHeight, profile: .compact, presentationReference: presentationReference)
            Text(PostcardDisplayLocation().resolveCompact(event.location))
                .font(.headline)
                .lineLimit(1)
                .accessibilityLabel(PostcardDisplayLocation().resolveSpoken(event.location))
            Text(event.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
public struct SupplyDrawerView: View {
    private let supplies: [Supply]
    private let selectedID: String?
    private let isCatAway: Bool
    private let errorText: String?
    private let select: (String?) -> Void
    private let close: () -> Void

    public init(
        supplies: [Supply],
        selectedID: String?,
        isCatAway: Bool = false,
        errorText: String? = nil,
        select: @escaping (String?) -> Void,
        close: @escaping () -> Void
    ) {
        self.supplies = supplies
        self.selectedID = selectedID
        self.isCatAway = isCatAway
        self.errorText = errorText
        self.select = select
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("旅行用品").font(.title3.bold())
                Spacer()
                Button("关闭", action: close).buttonStyle(.plain)
            }
            if isCatAway {
                Label("宠物已出发，下次准备时再选择。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            ScrollView {
                VStack(spacing: 8) {
                    supplyButton(id: nil, name: "不携带用品", influence: "清除当前选择")
                    ForEach(supplies) { supply in
                        supplyButton(id: supply.id, name: supply.name, influence: supply.influence)
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(12)
    }

    private func supplyButton(id: String?, name: String, influence: String) -> some View {
        Button { select(id) } label: {
            HStack {
                Image(systemName: selectedID == id ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading) {
                    Text(name)
                    Text(influence).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCatAway)
    }
}

@MainActor
public struct PetRootView: View {
    @ObservedObject private var model: AppModel
    private let presentationChanged: (PetPresentation) -> Void

    public init(
        model: AppModel,
        presentationChanged: @escaping (PetPresentation) -> Void = { _ in }
    ) {
        self.model = model
        self.presentationChanged = presentationChanged
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if model.presentation == model.basePresentation {
                Button { model.handle(.supplies) } label: {
                    Image(systemName: "backpack.fill")
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("旅行用品")
            }
        }
        .background(Color.clear)
        .onAppear { presentationChanged(model.presentation) }
        .onChange(of: model.presentation) { _, next in presentationChanged(next) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case .pet:
            PetHomeView(phase: model.snapshot.phase, profile: model.characterProfile, dataRoot: model.dataRoot, open: { destination in
                model.handle(destination)
            })
        case .awayTag:
            AwayTagView(open: { destination in
                model.handle(destination)
            })
        case .status:
            StatusBubbleView(
                text: model.snapshot.openHook ?? model.snapshot.mood.quote,
                mood: model.snapshot.mood.label,
                unreadPostcardID: model.nextUnreadPostcardID,
                base: model.basePresentation,
                albumAvailable: model.latestAvailableTripID() != nil,
                openAlbum: { model.openLatestAlbumFromStatus() }
            ) { destination in
                if case .pet = destination { model.close() }
                else if case .awayTag = destination { model.close() }
                else { model.handle(destination) }
            }
        case let .postcard(id):
            if let event = model.events.first(where: { $0.id == id }) {
                PostcardView(
                    event: event,
                    rootURL: model.dataRoot,
                    presentationReference: model.presentationReferences[event.id]
                ) { destination in
                    if destination == .status { model.close() }
                    else { model.handle(destination) }
                }
            } else {
                Button("返回") { model.close() }
            }
        case let .album(tripID):
            TripAlbumView(tripID: tripID, events: model.events, rootURL: model.dataRoot, presentationReferences: model.presentationReferences) { destination in
                if destination == .status { model.close() }
                else { model.handle(destination) }
            }
        case .supplies:
            SupplyDrawerView(
                supplies: model.supplies,
                selectedID: model.snapshot.carriedItemID,
                isCatAway: !(model.snapshot.phase == .resting || model.snapshot.phase == .preparing),
                errorText: model.supplyErrorMessage,
                select: { try? model.selectSupply($0) },
                close: model.close
            )
        }
    }
}

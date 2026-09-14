import AppKit
import SwiftUI
import TravelCore

public struct PetSpriteLayout: Equatable, Sendable {
    public let frameSize: CGSize
    public let columns: Int
    public let rows: Int

    public init(frameSize: CGSize, columns: Int, rows: Int) {
        precondition(frameSize.width > 0 && frameSize.height > 0)
        precondition(columns > 0 && rows > 0)
        self.frameSize = frameSize
        self.columns = columns
        self.rows = rows
    }

    public var sheetSize: CGSize {
        CGSize(
            width: frameSize.width * CGFloat(columns),
            height: frameSize.height * CGFloat(rows)
        )
    }

    public func frameOrigin(row: Int, frame: Int) -> CGPoint? {
        guard (0..<rows).contains(row), (0..<columns).contains(frame) else {
            return nil
        }

        return CGPoint(
            x: CGFloat(frame) * frameSize.width,
            y: CGFloat(row) * frameSize.height
        )
    }

    public func frameRect(row: Int, frame: Int) -> CGRect? {
        guard let origin = frameOrigin(row: row, frame: frame) else {
            return nil
        }

        return CGRect(origin: origin, size: frameSize)
    }

    public static let version2 = PetSpriteLayout(
        frameSize: CGSize(width: 192, height: 208),
        columns: 8,
        rows: 11
    )
}

public struct PetAnimation: Equatable, Sendable {
    public let row: Int
    public let frameCount: Int

    public init(row: Int, frameCount: Int) {
        self.row = row
        self.frameCount = frameCount
    }

    public static func animation(for phase: TravelPhase) -> PetAnimation {
        switch phase {
        case .resting:
            PetAnimation(row: 0, frameCount: 6)
        case .transit:
            PetAnimation(row: 1, frameCount: 8)
        case .preparing, .exploring, .postcardReady, .returning:
            PetAnimation(row: 8, frameCount: 6)
        }
    }
}

public enum PetSpriteResources {
    public static var manifestURL: URL? {
        TravelUIResources.bundle.url(forResource: "pet", withExtension: "json")
    }

    public static var spriteSheetURL: URL? {
        TravelUIResources.bundle.url(
            forResource: "cute-black-cat-spritesheet",
            withExtension: "webp"
        )
    }
}

@MainActor
public struct PetSpriteView: View {
    public static let displayScale: CGFloat = 0.58

    public let state: TravelPhase
    public let profile: CharacterProfile

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameIndex = 0

    private let layout = PetSpriteLayout.version2
    private let spriteSheet: NSImage?
    private let unavailable: Bool

    public init(state: TravelPhase, profile: CharacterProfile = .defaultBlackCat, dataRoot: URL? = nil) {
        self.state = state
        self.profile = profile
        switch CharacterSpriteResolver.resolve(profile: profile, dataRoot: dataRoot) {
        case let .available(url):
            spriteSheet = NSImage(contentsOf: url)
            unavailable = spriteSheet == nil
        case .unavailable:
            spriteSheet = nil
            unavailable = true
        }
    }

    public var body: some View {
        let animation = PetAnimation.animation(for: state)
        let selectedFrame = min(frameIndex, animation.frameCount - 1)
        let origin = layout.frameOrigin(row: animation.row, frame: selectedFrame) ?? .zero
        let scale = Self.displayScale
        let displaySize = CGSize(
            width: layout.frameSize.width * scale,
            height: layout.frameSize.height * scale
        )

        ZStack(alignment: .topLeading) {
            if let spriteSheet {
                Image(nsImage: spriteSheet)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: layout.sheetSize.width * scale,
                        height: layout.sheetSize.height * scale
                    )
                    .offset(x: -origin.x * scale, y: -origin.y * scale)
            } else if unavailable {
                VStack(spacing: 6) {
                    Image(systemName: "questionmark.diamond")
                        .font(.system(size: 34, weight: .light))
                    Text("角色资源不可用")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(width: displaySize.width, height: displaySize.height)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
        .clipped()
        .accessibilityLabel(profile.displayName)
        .task(id: animationTaskID) {
            frameIndex = 0
            guard !reduceMotion else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                frameIndex = (frameIndex + 1) % animation.frameCount
            }
        }
        .onDisappear {
            frameIndex = 0
        }
    }

    private var animationTaskID: String {
        "\(state.rawValue)-\(reduceMotion)"
    }
}

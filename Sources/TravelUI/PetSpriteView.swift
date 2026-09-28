import AppKit
import SwiftUI
import TravelCore

private struct PetPlaybackEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    var petPlaybackEnabled: Bool {
        get { self[PetPlaybackEnabledKey.self] }
        set { self[PetPlaybackEnabledKey.self] = newValue }
    }
}

struct PetPlaybackIdentity: Equatable {
    let phase: TravelPhase
    let profile: CharacterProfile
    let reduceMotion: Bool
    let visible: Bool
    let available: Bool
    let dataRoot: URL?
    var explicitAnimation: PetAnimation? = nil
    var frameDuration: Double = 0.18
    var enabled: Bool { !reduceMotion && visible && available }
}

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
    public let frames: [Int]
    public var frameCount: Int { frames.count }

    public init(row: Int, frameCount: Int) {
        self.row = row
        self.frames = Array(0..<frameCount)
    }

    public init(row: Int, frames: [Int]) {
        precondition(!frames.isEmpty && frames.allSatisfy { (0..<8).contains($0) })
        self.row = row
        self.frames = frames
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
    private var explicitAnimation: PetAnimation?
    private let isAnimating: Bool
    private var frameDuration: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.petPlaybackEnabled) private var playbackEnabled
    @State private var explicitFrameIndex = 0
    @State private var playback = PetPlaybackState()
    @State private var playbackIdentity: PetPlaybackIdentity?

    private let layout = PetSpriteLayout.version2
    private let spriteSheet: NSImage?
    private let unavailable: Bool
    private let dataRoot: URL?
    private var requiresReducedMotion = false

    init(state: TravelPhase, requiresReducedMotion: Bool) {
        self.init(state: state)
        self.requiresReducedMotion = requiresReducedMotion
    }

    public init(state: TravelPhase, profile: CharacterProfile = .defaultBlackCat, dataRoot: URL? = nil, isAnimating: Bool = true) {
        self.state = state
        self.profile = profile
        self.dataRoot = dataRoot
        switch CharacterSpriteResolver.resolve(profile: profile, dataRoot: dataRoot) {
        case let .available(url):
            spriteSheet = NSImage(contentsOf: url)
            unavailable = spriteSheet == nil
        case .unavailable:
            spriteSheet = nil
            unavailable = true
        }
        self.explicitAnimation = nil
        self.isAnimating = isAnimating
        self.frameDuration = 0.18
    }

    public init(animation: PetAnimation, isAnimating: Bool = true, frameDuration: Double = 0.18) {
        self.init(state: .resting, isAnimating: isAnimating)
        self.explicitAnimation = animation
        self.frameDuration = max(0.1, frameDuration)
    }

    private var selectedAnimation: PetAnimation { explicitAnimation ?? PetAnimation.animation(for: state) }

    public var body: some View {
        let identity = animationTaskID
        let active = playbackIdentity == identity && identity.enabled
        let animation = explicitAnimation ?? (active ? playback.animation : selectedAnimation)
        let index = active ? (explicitAnimation == nil ? playback.frameIndex : explicitFrameIndex) : 0
        let selectedFrame = animation.frames[min(index, animation.frameCount - 1)]
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
                    .transaction { $0.animation = nil }
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
            explicitFrameIndex = 0
            playback.reset(phase: state, profile: profile, enabled: identity.enabled)
            playbackIdentity = identity
            guard identity.enabled else { return }

            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(frameDuration)) }
                catch { return }
                guard !Task.isCancelled else { return }
                if let explicitAnimation {
                    explicitFrameIndex = (explicitFrameIndex + 1) % explicitAnimation.frameCount
                } else {
                    playback.advance(choice: Int.random(in: Int.min...Int.max))
                }
            }
        }
        .onDisappear {
            playback.reset(phase: state, profile: profile, enabled: false)
            playbackIdentity = nil
        }
    }

    private var animationTaskID: PetPlaybackIdentity {
        PetPlaybackIdentity(phase: state, profile: profile, reduceMotion: reduceMotion || requiresReducedMotion,
                            visible: playbackEnabled && isAnimating, available: !unavailable, dataRoot: dataRoot,
                            explicitAnimation: explicitAnimation, frameDuration: frameDuration)
    }
}

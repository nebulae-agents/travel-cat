import CoreGraphics

enum PetCompanionEdge: Equatable {
    case bottomTrailing
    case bottomLeading
    case trailing
    case leading
}

struct PetCompanionPlacement: Equatable {
    let frame: CGRect
    let edge: PetCompanionEdge
}

enum PetCompanionLayout {
    static let gap: CGFloat = 12

    static func offset(anchor: CGRect, companion: CGRect) -> CGPoint? {
        guard anchor.isFiniteNonempty, companion.isFiniteNonempty else { return nil }
        let result = CGPoint(x: companion.midX - anchor.midX, y: companion.midY - anchor.midY)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    static func place(anchor: CGRect, companionSize: CGSize, offset: CGPoint, visibleFrames: [CGRect]) -> PetCompanionPlacement? {
        guard anchor.isFiniteNonempty, offset.x.isFinite, offset.y.isFinite else { return nil }
        var frame = CGRect(x: anchor.midX + offset.x - companionSize.width / 2,
                           y: anchor.midY + offset.y - companionSize.height / 2,
                           width: companionSize.width, height: companionSize.height)
        guard frame.isFiniteNonempty else { return nil }
        let screens = visibleFrames.filter {
            $0.isFiniteNonempty && $0.size.width >= companionSize.width && $0.size.height >= companionSize.height
        }
        guard !screens.isEmpty else { return nil }
        // Keep the interactive center reachable, even when only transparent padding remains.
        if !screens.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
            let screen = screens.min { lhs, rhs in
                hypot(lhs.midX - anchor.midX, lhs.midY - anchor.midY)
                    < hypot(rhs.midX - anchor.midX, rhs.midY - anchor.midY)
            }!
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        }
        return PetCompanionPlacement(frame: frame, edge: offset.x >= 0 ? .leading : .trailing)
    }

    static func place(
        anchor: CGRect,
        companionSize: CGSize,
        visibleFrame: CGRect
    ) -> PetCompanionPlacement? {
        guard anchor.isFiniteNonempty,
              visibleFrame.isFiniteNonempty,
              companionSize.width.isFinite,
              companionSize.height.isFinite,
              companionSize.width > 0,
              companionSize.height > 0
        else {
            return nil
        }

        let leftCandidates: [(frame: CGRect, edge: PetCompanionEdge)] = [
            (
                CGRect(
                    x: anchor.minX - companionSize.width - gap,
                    y: anchor.midY - companionSize.height / 2,
                    width: companionSize.width,
                    height: companionSize.height
                ),
                .trailing
            ),
            (
                CGRect(
                    x: anchor.minX - companionSize.width - gap,
                    y: anchor.maxY - companionSize.height,
                    width: companionSize.width,
                    height: companionSize.height
                ),
                .bottomTrailing
            ),
        ]

        let rightCandidates: [(frame: CGRect, edge: PetCompanionEdge)] = [
            (
                CGRect(
                    x: anchor.maxX + gap,
                    y: anchor.midY - companionSize.height / 2,
                    width: companionSize.width,
                    height: companionSize.height
                ),
                .leading
            ),
            (
                CGRect(
                    x: anchor.maxX + gap,
                    y: anchor.maxY - companionSize.height,
                    width: companionSize.width,
                    height: companionSize.height
                ),
                .bottomLeading
            ),
        ]

        let leftSpace = anchor.minX - visibleFrame.minX
        let rightSpace = visibleFrame.maxX - anchor.maxX
        let candidates = leftSpace >= rightSpace
            ? leftCandidates + rightCandidates
            : rightCandidates + leftCandidates

        return candidates.first {
            $0.frame.isFiniteNonempty
                && visibleFrame.contains($0.frame)
                && !$0.frame.intersects(anchor)
        }.map {
            PetCompanionPlacement(frame: $0.frame, edge: $0.edge)
        }
    }
}

extension CGRect {
    var isFiniteNonempty: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && maxX.isFinite
            && maxY.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }
}

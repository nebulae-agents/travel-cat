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

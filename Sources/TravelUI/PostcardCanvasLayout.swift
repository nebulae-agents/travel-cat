import SwiftUI

/// One fitted canvas for the artwork, text and clipping boundary. A wide parent
/// proposal must not turn a square postcard into a letterboxed landscape card.
struct PostcardCanvasLayout: Layout {
    var imageSize: CGSize?
    var maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard maximumHeight.isFinite, maximumHeight > 0 else { return .zero }
        guard let imageSize, imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: max(proposal.width ?? maximumHeight, 0), height: maximumHeight)
        }
        let aspect = imageSize.width / imageSize.height
        let idealWidth = maximumHeight * aspect
        let availableWidth = proposal.width.flatMap { $0.isFinite ? max($0, 0) : nil } ?? idealWidth
        let width = min(availableWidth, idealWidth)
        return CGSize(width: width, height: width / aspect)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(bounds.size))
        }
    }
}

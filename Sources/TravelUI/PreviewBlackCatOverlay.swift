import AppKit
import SwiftUI

struct PreviewBlackCatOverlay: View {
    let descriptor: PreviewBlackCatOverlayDescriptor
    let containerSize: CGSize
    let profile: PostcardOverlayProfile

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = NSImage(contentsOf: descriptor.assetURL),
               image.size.width > 0,
               image.size.height > 0 {
                let frame = descriptor.placement.frame(
                    in: containerSize,
                    sourceAspectRatio: image.size.width / image.size.height
                )
                Ellipse()
                    .fill(.black.opacity(0.18))
                    .frame(
                        width: frame.width * 0.72,
                        height: max(frame.height * 0.08, 2)
                    )
                    .blur(radius: profile == .detail ? 3 : 1.5)
                    .position(
                        x: frame.midX,
                        y: frame.maxY - frame.height * 0.015
                    )

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(
                        x: descriptor.placement.isMirrored ? -1 : 1,
                        y: 1
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(
            width: containerSize.width,
            height: containerSize.height,
            alignment: .topLeading
        )
    }
}

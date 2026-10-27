import AppKit
import SwiftUI

/// Shares the cottage's packaged illustration resources, including offline preview hosts.
public struct PetMailboxAssetView: View {
    private static let artwork = TravelUIResources.bundle.url(forResource: "pet-mailbox", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    public init() {}
    public var body: some View {
        if let artwork = Self.artwork {
            Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "mailbox").resizable().scaledToFit().foregroundStyle(Color(red: 0.31, green: 0.39, blue: 0.23))
        }
    }
}

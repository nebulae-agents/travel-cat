import Foundation

public enum TravelUIModule {}

enum TravelUIResources {
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent("TravelCat_TravelUI.bundle")) {
            return packaged
        }
        return Bundle.module
    }()
}

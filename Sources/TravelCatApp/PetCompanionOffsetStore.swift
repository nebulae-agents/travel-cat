import Foundation
import CoreGraphics

struct PetCompanionOffsetStore {
    static let key = "petCompanion.centerOffset.v1"
    let defaults: UserDefaults

    func load() -> CGPoint? {
        guard let record = defaults.dictionary(forKey: Self.key),
              let version = record["version"] as? NSNumber, version.doubleValue == 1,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              let x = record["x"] as? NSNumber,
              let y = record["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(),
              CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite else { return nil }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    func save(_ offset: CGPoint) {
        guard offset.x.isFinite, offset.y.isFinite else { return }
        defaults.set(["version": 1, "x": Double(offset.x), "y": Double(offset.y)], forKey: Self.key)
    }
}

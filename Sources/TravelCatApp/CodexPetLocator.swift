import AppKit
import CoreFoundation
import CoreGraphics
import Darwin

struct CodexWindowRecord: Equatable {
    let number: Int
    let ownerPID: pid_t
    let owner: String
    let name: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect

    init(
        number: Int,
        ownerPID: pid_t,
        owner: String,
        name: String,
        layer: Int,
        alpha: Double,
        bounds: CGRect
    ) {
        self.number = number
        self.ownerPID = ownerPID
        self.owner = owner
        self.name = name
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }

    init?(dictionary: [String: Any]) {
        let name: String
        if let rawName = dictionary[kCGWindowName as String] {
            guard let decodedName = rawName as? String else { return nil }
            name = decodedName
        } else {
            name = ""
        }

        guard let rawNumber = dictionary[kCGWindowNumber as String],
              !Self.isBoolean(rawNumber),
              let number = rawNumber as? Int,
              let ownerPID = Self.decodeOwnerPID(dictionary[kCGWindowOwnerPID as String]),
              let owner = dictionary[kCGWindowOwnerName as String] as? String,
              let rawLayer = dictionary[kCGWindowLayer as String],
              !Self.isBoolean(rawLayer),
              let layer = rawLayer as? Int,
              let rawAlpha = dictionary[kCGWindowAlpha as String],
              !Self.isBoolean(rawAlpha),
              let alpha = rawAlpha as? Double,
              alpha.isFinite,
              let bounds = Self.decodeBounds(dictionary[kCGWindowBounds as String])
        else {
            return nil
        }

        self.init(
            number: number,
            ownerPID: ownerPID,
            owner: owner,
            name: name,
            layer: layer,
            alpha: alpha,
            bounds: bounds
        )
    }

    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID()
    }

    private static func decodeOwnerPID(_ value: Any?) -> pid_t? {
        guard let value,
              !isBoolean(value),
              let number = value as? NSNumber
        else {
            return nil
        }
        let floatingPointValue = number.doubleValue
        let integerValue = number.int64Value
        guard floatingPointValue.isFinite,
              floatingPointValue == Double(integerValue),
              integerValue > 0,
              integerValue <= Int64(Int32.max)
        else {
            return nil
        }
        return pid_t(integerValue)
    }

    private static func decodeBounds(_ value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary,
              let x = finiteCGFloat(dictionary["X"]),
              let y = finiteCGFloat(dictionary["Y"]),
              let width = finiteCGFloat(dictionary["Width"]),
              let height = finiteCGFloat(dictionary["Height"]),
              width > 0,
              height > 0
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func finiteCGFloat(_ value: Any?) -> CGFloat? {
        guard let value,
              !isBoolean(value),
              let number = value as? NSNumber
        else {
            return nil
        }
        let result = CGFloat(number.doubleValue)
        return result.isFinite ? result : nil
    }

    private var hasValidCommonMetadata: Bool {
        ownerPID > 0
            && layer >= 0
            && alpha.isFinite
            && alpha > 0
            && bounds.size.width > 0
            && bounds.size.height > 0
            && bounds.size.width <= 1_024
            && bounds.size.height <= 1_024
            && abs(bounds.origin.x) <= 100_000
            && abs(bounds.origin.y) <= 100_000
            && bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.size.width.isFinite
            && bounds.size.height.isFinite
    }

    private var hasLegacySignature: Bool {
        owner == "ChatGPT" && name == "Codex Pet Mascot Effect"
    }

    var isValidMascot: Bool {
        hasValidCommonMetadata && hasLegacySignature
    }

    func isValidMascot(ownerBundleIdentifier: String?) -> Bool {
        mascotSelectionPriority(ownerBundleIdentifier: ownerBundleIdentifier) != nil
    }

    func mascotSelectionPriority(ownerBundleIdentifier: String?) -> Int? {
        guard isValidMascot, ownerBundleIdentifier == "com.openai.codex" else { return nil }
        return 1
    }
}

struct CodexPetSelection: Equatable {
    enum Source: Equatable {
        case persistedOverlay
        case legacyWindow(CodexWindowRecord)
    }

    let ownerPID: pid_t
    let inputBounds: CGRect
    let appKitBounds: CGRect
    let screenFrame: CGRect
    let source: Source

    var record: CodexWindowRecord? {
        if case .legacyWindow(let record) = source { return record }
        return nil
    }

    init(ownerPID: pid_t, inputBounds: CGRect, appKitBounds: CGRect, screenFrame: CGRect, source: Source) {
        self.ownerPID = ownerPID
        self.inputBounds = inputBounds
        self.appKitBounds = appKitBounds
        self.screenFrame = screenFrame
        self.source = source
    }

    init(record: CodexWindowRecord, appKitBounds: CGRect, screenFrame: CGRect) {
        self.init(ownerPID: record.ownerPID, inputBounds: record.bounds,
                  appKitBounds: appKitBounds, screenFrame: screenFrame, source: .legacyWindow(record))
    }

    func appKitPoint(fromInput point: CGPoint) -> CGPoint {
        CGPoint(x: appKitBounds.minX + point.x - inputBounds.minX,
                y: appKitBounds.maxY - (point.y - inputBounds.minY))
    }
}

struct CodexScreenRecord: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let displayID: UInt32?

    init(frame: CGRect, visibleFrame: CGRect, displayID: UInt32? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.displayID = displayID
    }

    var isValid: Bool {
        frame.isFiniteNonempty
            && visibleFrame.isFiniteNonempty
            && frame.contains(visibleFrame)
    }
}

enum CodexPetLocator {
    static func resolve(
        overlay: CodexPetOverlayReadResult,
        ownerPID: pid_t?,
        records: [CodexWindowRecord],
        mouseLocation: CGPoint,
        screens: [CodexScreenRecord],
        bundleIdentifierForOwnerPID: (pid_t) -> String?
    ) -> CodexPetSelection? {
        guard let ownerPID, ownerPID > 0,
              bundleIdentifierForOwnerPID(ownerPID) == "com.openai.codex",
              let primary = screens.first, primary.isValid else { return nil }
        switch overlay {
        case .hidden:
            return nil
        case .unavailable:
            return select(records: records.filter { $0.ownerPID == ownerPID },
                          mouseLocation: mouseLocation, screens: screens,
                          bundleIdentifierForOwnerPID: bundleIdentifierForOwnerPID)
        case .visible(let anchor):
            let matching = screens.filter { $0.isValid && $0.displayID == anchor.displayID }
            guard matching.count == 1, let screen = matching.first,
                  anchor.inputBounds.isFiniteNonempty,
                  anchor.displayBounds.isFiniteNonempty,
                  appKitBounds(from: anchor.displayBounds, primaryFrame: primary.frame) == screen.frame
            else { return nil }
            let bounds = appKitBounds(from: anchor.inputBounds, primaryFrame: primary.frame)
            guard bounds.isFiniteNonempty, screen.frame.contains(bounds) else { return nil }
            return CodexPetSelection(ownerPID: ownerPID, inputBounds: anchor.inputBounds,
                                     appKitBounds: bounds, screenFrame: screen.visibleFrame,
                                     source: .persistedOverlay)
        }
    }

    @MainActor
    static func currentSelection() -> CodexPetSelection? {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated }
        guard applications.count == 1, let application = applications.first else { return nil }
        let overlay = CodexPetStateReader.read()
        let records: [CodexWindowRecord]
        if case .unavailable = overlay { records = currentRecords() } else { records = [] }
        return resolve(
            overlay: overlay, ownerPID: application.processIdentifier, records: records,
            mouseLocation: NSEvent.mouseLocation,
            screens: NSScreen.screens.map {
                CodexScreenRecord(frame: $0.frame, visibleFrame: $0.visibleFrame,
                                  displayID: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
            },
            bundleIdentifierForOwnerPID: currentBundleIdentifier(forOwnerPID:)
        )
    }

    static func currentRecords() -> [CodexWindowRecord] {
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return rows.compactMap(CodexWindowRecord.init(dictionary:))
    }

    static func appKitBounds(from cgBounds: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: cgBounds.minX,
            y: primaryFrame.maxY - cgBounds.maxY,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    static func currentBundleIdentifier(forOwnerPID ownerPID: pid_t) -> String? {
        NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
    }

    static func select(
        records: [CodexWindowRecord],
        mouseLocation: CGPoint,
        screens: [CodexScreenRecord],
        bundleIdentifierForOwnerPID: (pid_t) -> String? = { _ in nil }
    ) -> CodexPetSelection? {
        guard let primaryScreen = screens.first, primaryScreen.isValid else {
            return nil
        }

        let validScreens = screens.filter(\.isValid)
        let mouseScreen = validScreens.first { $0.frame.contains(mouseLocation) }
        let candidates = records.compactMap { record -> (CodexPetSelection, CGFloat, Bool, Int)? in
            let ownerBundleIdentifier = bundleIdentifierForOwnerPID(record.ownerPID)
            guard let selectionPriority = record.mascotSelectionPriority(
                ownerBundleIdentifier: ownerBundleIdentifier
            ) else {
                return nil
            }

            let bounds = appKitBounds(from: record.bounds, primaryFrame: primaryScreen.frame)
            guard bounds.isFiniteNonempty else {
                return nil
            }

            let intersections = validScreens.map { screen -> (screen: CodexScreenRecord, area: CGFloat) in
                let overlap = bounds.intersection(screen.frame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return (screen, area)
            }
            guard let best = intersections.enumerated().max(by: {
                $0.element.area == $1.element.area
                    ? $0.offset > $1.offset
                    : $0.element.area < $1.element.area
            }), best.element.area > 0 else {
                return nil
            }

            let selection = CodexPetSelection(
                record: record,
                appKitBounds: bounds,
                screenFrame: best.element.screen.visibleFrame
            )
            let intersectsMouseScreen = mouseScreen.map { bounds.intersects($0.frame) } ?? false
            return (selection, best.element.area, intersectsMouseScreen, selectionPriority)
        }

        let orderedCandidates = candidates.sorted {
            if $0.3 != $1.3 {
                return $0.3 > $1.3
            }
            if $0.2 != $1.2 {
                return $0.2 && !$1.2
            }
            if $0.1 != $1.1 {
                return $0.1 > $1.1
            }
            return ($0.0.record?.number ?? Int.max) < ($1.0.record?.number ?? Int.max)
        }

        guard let highestPriority = orderedCandidates.first?.3 else { return nil }
        if highestPriority == 0,
           orderedCandidates.filter({ $0.3 == highestPriority }).count > 1 {
            return nil
        }
        return orderedCandidates.first?.0
    }
}

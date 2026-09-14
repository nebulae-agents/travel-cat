import AppKit
import XCTest
@testable import TravelCatApp

final class CodexPetOverlayLocatorTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let input = CGRect(x: 1301, y: 148, width: 100, height: 109)

    func testObservedStateWinsOverWrongLeftWindowAndExactLegacyWindow() throws {
        let selected = try XCTUnwrap(resolve())
        XCTAssertEqual(selected.appKitBounds, CGRect(x: 1301, y: 725, width: 100, height: 109))
        XCTAssertEqual(selected.screenFrame, CGRect(x: 0, y: 0, width: 1469, height: 949))
        XCTAssertEqual(selected.source, .persistedOverlay)
        XCTAssertEqual(selected.inputBounds, input)
        XCTAssertEqual(selected.appKitPoint(fromInput: CGPoint(x: 1351, y: 198)), CGPoint(x: 1351, y: 784))
    }

    func testHiddenOrUntrustedOrExitedCodexNeverUsesStaleWindow() {
        XCTAssertNil(resolve(overlay: .hidden))
        XCTAssertNil(resolve(pid: nil))
        XCTAssertNil(resolve(bundle: nil))
        XCTAssertNil(resolve(bundle: "com.example.spoof"))
    }

    func testMismatchedDisplayIDOrGeometryFailsClosed() {
        XCTAssertNil(resolve(overlay: .visible(.init(inputBounds: input, displayBounds: frame, displayID: 9))))
        XCTAssertNil(resolve(overlay: .visible(.init(
            inputBounds: input,
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), displayID: 1))))
        XCTAssertNil(resolve(overlay: .visible(.init(
            inputBounds: CGRect(x: 1511, y: 148, width: 100, height: 109),
            displayBounds: frame, displayID: 1))))
    }

    func testUnavailableStateUsesOnlyExactTrustedLegacyWindow() throws {
        let selected = try XCTUnwrap(resolve(overlay: .unavailable))
        XCTAssertEqual(selected.appKitBounds.minX, 15)
        XCTAssertNil(resolve(overlay: .unavailable, includeLegacy: false))
    }

    func testNegativeUpperDisplayCoordinatesConvertUsingPrimaryScreen() throws {
        let upper = CGRect(x: -1000, y: 982, width: 1000, height: 800)
        let screen = CodexScreenRecord(frame: upper, visibleFrame: upper, displayID: 2)
        let selected = try XCTUnwrap(CodexPetLocator.resolve(
            overlay: .visible(.init(inputBounds: CGRect(x: -900, y: -700, width: 100, height: 109),
                                    displayBounds: CGRect(x: -1000, y: -800, width: 1000, height: 800), displayID: 2)),
            ownerPID: 1129, records: [], mouseLocation: .zero,
            screens: [CodexScreenRecord(frame: frame, visibleFrame: frame, displayID: 1), screen],
            bundleIdentifierForOwnerPID: { _ in "com.openai.codex" }
        ))
        XCTAssertEqual(selected.appKitBounds, CGRect(x: -900, y: 1573, width: 100, height: 109))
        XCTAssertEqual(selected.screenFrame, upper)
    }

    private func resolve(
        overlay: CodexPetOverlayReadResult? = nil,
        pid: pid_t? = 1129,
        bundle: String? = "com.openai.codex",
        includeLegacy: Bool = true
    ) -> CodexPetSelection? {
        let left = CGRect(x: 15, y: 732, width: 132, height: 175)
        var records = [CodexWindowRecord(number: 1, ownerPID: 1129, owner: "ChatGPT",
                                        name: "ChatGPT", layer: 0, alpha: 1, bounds: left)]
        if includeLegacy {
            records.append(CodexWindowRecord(number: 2, ownerPID: 1129, owner: "ChatGPT",
                                             name: "Codex Pet Mascot Effect", layer: 2, alpha: 1, bounds: left))
        }
        return CodexPetLocator.resolve(
            overlay: overlay ?? .visible(.init(inputBounds: input, displayBounds: frame, displayID: 1)),
            ownerPID: pid, records: records, mouseLocation: .zero,
            screens: [.init(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1469, height: 949), displayID: 1)],
            bundleIdentifierForOwnerPID: { _ in bundle }
        )
    }
}

import CoreGraphics
import Foundation
import XCTest
@testable import TravelCatApp

final class CodexPetStateReaderTests: XCTestCase {
    func testRejectsAnchorWithOnlyOnePixelInsideDeclaredDisplay() {
        let state = Data(#"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1511,"y":148,"displayBounds":{"x":0,"y":0,"width":1512,"height":982},"displayId":1}}"#.utf8)
        XCTAssertEqual(CodexPetStateReader.parse(stateData: state, configuration: nil), .unavailable)
    }

    func testReadsObservedOverlayShapeAndUsesConfiguredWidth() throws {
        let state = #"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1301,"y":148,"displayBounds":{"x":0,"y":0,"width":1512,"height":982},"displayId":1,"placement":"bottom-end","byDisplayId":{"1":{"x":99}}},"historical":true}"#.data(using: .utf8)
        let result = CodexPetStateReader.parse(stateData: state, configuration: "[desktop]\navatar-overlay-mascot-width-px = 100\n[other]\navatar-overlay-mascot-width-px = 224\n")
        XCTAssertEqual(result, .visible(CodexPetOverlayAnchor(inputBounds: CGRect(x: 1301, y: 148, width: 100, height: 109), displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 982), displayID: 1)))
    }

    func testMissingOrCorruptStateIsUnavailable() {
        XCTAssertEqual(CodexPetStateReader.parse(stateData: nil, configuration: nil), .unavailable)
        XCTAssertEqual(CodexPetStateReader.parse(stateData: Data("not json".utf8), configuration: nil), .unavailable)
    }

    func testClosedOverlayOrHiddenPetIsHiddenEvenWhenBoundsAreMalformed() {
        let malformed = Data(#"{"electron-avatar-overlay-open":false,"electron-avatar-overlay-bounds":null}"#.utf8)
        XCTAssertEqual(CodexPetStateReader.parse(stateData: malformed, configuration: nil), .hidden)
        let hidden = Data(#"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1,"y":2,"displayBounds":{"x":0,"y":0,"width":100,"height":100},"displayId":1}}"#.utf8)
        XCTAssertEqual(CodexPetStateReader.parse(stateData: hidden, configuration: "[desktop]\n avatar-overlay-pet-visible = false"), .hidden)
    }

    func testRejectsInvalidNumericValuesAndOutOfDisplayBounds() {
        let cases = [
            #"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":true,"y":2,"displayBounds":{"x":0,"y":0,"width":100,"height":100},"displayId":1}}"#,
            #"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1.5,"y":2,"displayBounds":{"x":0,"y":0,"width":100,"height":100},"displayId":1.5}}"#,
            #"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1000,"y":2,"displayBounds":{"x":0,"y":0,"width":100,"height":100},"displayId":1}}"#,
            #"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1,"y":2,"displayBounds":{"x":0,"y":0,"width":0,"height":100},"displayId":1}}"#,
        ]
        for value in cases { XCTAssertEqual(CodexPetStateReader.parse(stateData: Data(value.utf8), configuration: nil), .unavailable) }
    }

    func testRejectsBooleanOverlayOpenAndInvalidDisplayIDs() {
        func json(displayID: String, open: String = "true") -> Data {
            Data("{\"electron-avatar-overlay-open\":\(open),\"electron-avatar-overlay-bounds\":{\"x\":1,\"y\":2,\"displayBounds\":{\"x\":0,\"y\":0,\"width\":1000,\"height\":1000},\"displayId\":\(displayID)}}".utf8)
        }
        let invalidOpen = json(displayID: "1", open: "1")
        XCTAssertEqual(CodexPetStateReader.parse(stateData: invalidOpen, configuration: nil), .unavailable)
        for value in ["true", "0", "1.5", "4294967296", "NaN", "Infinity", "1e400"] {
            XCTAssertEqual(CodexPetStateReader.parse(stateData: json(displayID: value), configuration: nil), .unavailable)
        }
    }

    func testAcceptsNegativeMonitorCoordinatesAndIgnoresKeysOutsideDesktop() {
        let state = Data(#"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":-1301,"y":-400,"displayBounds":{"x":-1512,"y":-982,"width":1512,"height":982},"displayId":2}}"#.utf8)
        let result = CodexPetStateReader.parse(stateData: state, configuration: "avatar-overlay-mascot-width-px = 80\n[\"desktop\"] # comment\navatar-overlay-mascot-width-px=224 # inline\n")
        XCTAssertEqual(result, .visible(CodexPetOverlayAnchor(inputBounds: CGRect(x: -1301, y: -400, width: 224, height: 243), displayBounds: CGRect(x: -1512, y: -982, width: 1512, height: 982), displayID: 2)))
    }

    func testInvalidWidthUsesDefaultAndFractionalWidthIsIgnored() {
        let state = Data(#"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1,"y":2,"displayBounds":{"x":0,"y":0,"width":1000,"height":1000},"displayId":1}}"#.utf8)
        for config in ["[desktop]\navatar-overlay-mascot-width-px=79", "[desktop]\navatar-overlay-mascot-width-px=225", "[desktop]\navatar-overlay-mascot-width-px=100.5"] {
            XCTAssertEqual(CodexPetStateReader.parse(stateData: state, configuration: config), .visible(CodexPetOverlayAnchor(inputBounds: CGRect(x: 1, y: 2, width: 112, height: 122), displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), displayID: 1)))
        }
    }

    func testReadRereadsFilesFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        let state = dir.appendingPathComponent(".codex-global-state.json")
        try Data("[desktop]\navatar-overlay-mascot-width-px=80".utf8).write(to: config)
        try Data(#"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":1,"y":2,"displayBounds":{"x":0,"y":0,"width":1000,"height":1000},"displayId":1}}"#.utf8).write(to: state)
        XCTAssertEqual(CodexPetStateReader.read(codexDirectory: dir), .visible(CodexPetOverlayAnchor(inputBounds: CGRect(x: 1, y: 2, width: 80, height: 87), displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), displayID: 1)))
        try Data("[desktop]\navatar-overlay-mascot-width-px=224".utf8).write(to: config)
        XCTAssertEqual(CodexPetStateReader.read(codexDirectory: dir), .visible(CodexPetOverlayAnchor(inputBounds: CGRect(x: 1, y: 2, width: 224, height: 243), displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), displayID: 1)))
        try Data(#"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":401,"y":302,"displayBounds":{"x":0,"y":0,"width":1000,"height":1000},"displayId":1}}"#.utf8).write(to: state)
        XCTAssertEqual(CodexPetStateReader.read(codexDirectory: dir), .visible(CodexPetOverlayAnchor(inputBounds: CGRect(x: 401, y: 302, width: 224, height: 243), displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), displayID: 1)))
        try Data("[desktop]\navatar-overlay-pet-visible=false".utf8).write(to: config)
        XCTAssertEqual(CodexPetStateReader.read(codexDirectory: dir), .hidden)
    }
}

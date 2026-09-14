import Darwin
import Foundation
import XCTest
@testable import TravelCatApp

final class JourneyTestGeneratedImageReaderTests: XCTestCase {
  func testReadsOnlyBoundedRegularOwnedBytes() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("ink.png")
    try Data([1, 2, 3]).write(to: file)
    let reader = JourneyTestGeneratedImageReader(allowedRoot: root, maximumBytes: 3)
    XCTAssertEqual(try reader.read(path: file.path), Data([1, 2, 3]))
    try Data([1, 2, 3, 4]).write(to: file)
    XCTAssertThrowsError(try reader.read(path: file.path))
    try Data().write(to: file)
    XCTAssertThrowsError(try reader.read(path: file.path))
  }

  func testRejectsLinksTraversalAndReplacement() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("ink.png")
    try Data([1, 2, 3]).write(to: file)
    let reader = JourneyTestGeneratedImageReader(allowedRoot: root)
    let alias = root.appendingPathComponent("alias.png")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    XCTAssertThrowsError(try reader.read(path: alias.path))
    let parent = root.appendingPathComponent("parent")
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
    XCTAssertThrowsError(try reader.read(path: parent.appendingPathComponent("ink.png").path))
    XCTAssertThrowsError(try reader.read(path: root.path + "/../" + root.lastPathComponent + "/ink.png"))
    XCTAssertThrowsError(try reader.read(path: file.absoluteString))
    let hard = root.appendingPathComponent("hard.png")
    XCTAssertEqual(link(file.path, hard.path), 0)
    XCTAssertThrowsError(try reader.read(path: file.path))
    try FileManager.default.removeItem(at: hard)
    let replacing = JourneyTestGeneratedImageReader(allowedRoot: root, beforeRevalidation: {
      try Data([4, 5, 6]).write(to: file, options: .atomic)
    })
    XCTAssertThrowsError(try replacing.read(path: file.path))
  }
}

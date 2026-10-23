import AppKit
import XCTest
@testable import TravelCatApp

final class MailboxInboxTests: XCTestCase {
    func testEmptySingleMultipleAndCappedBadge() {
        XCTAssertEqual(MailboxInbox(entries: []).badge, nil)
        let card = MailboxEntry.postcard(id: UUID(), date: .distantPast)
        XCTAssertEqual(MailboxInbox(entries: [card]).badge, "1")
        XCTAssertEqual(MailboxInbox(entries: [card]).singleEntry?.id, card.id)
        let many = (0..<101).map { _ in MailboxEntry.postcard(id: UUID(), date: .distantPast) }
        XCTAssertEqual(MailboxInbox(entries: many).badge, "99+")
        XCTAssertNil(MailboxInbox(entries: many).singleEntry)
    }
    func testApprovalsMergePerTaskAndActiveProgressDoesNotNotify() {
        var task = WorkbenchTask(instanceID: UUID(), title: "确认任务")
        task.status = .running; task.unread = true
        XCTAssertTrue(MailboxInbox.project(tasks: [task], pendingTaskIDs: [], postcards: []).entries.isEmpty)
        let inbox = MailboxInbox.project(tasks: [task], pendingTaskIDs: [task.id, task.id], postcards: [])
        XCTAssertEqual(inbox.entries.count, 1)
        XCTAssertEqual(inbox.entries.first?.kind, .approval)
        XCTAssertTrue(task.unread, "Projection must not mark read")
    }
    func testPriorityAndReadFiltering() {
        var result = WorkbenchTask(instanceID: UUID(), title: "结果"); result.status = .completed; result.unread = true
        var failure = WorkbenchTask(instanceID: UUID(), title: "异常"); failure.status = .failed; failure.unread = true
        var approval = WorkbenchTask(instanceID: UUID(), title: "确认"); approval.status = .running
        var read = result; read.id = UUID(); read.unread = false
        let card = MailboxEntry.postcard(id: UUID(), date: Date())
        let inbox = MailboxInbox.project(tasks: [result, read, approval, failure], pendingTaskIDs: [approval.id], postcards: [card, card])
        XCTAssertEqual(inbox.entries.map(\.kind), [.approval, .failure, .result, .postcard])
        XCTAssertEqual(inbox.entries.map(\.title).prefix(3), ["确认", "异常", "结果"])
    }
    func testCustomOffsetFollowsHouseAndClampingDoesNotErasePreference() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let house = CGRect(x: 400, y: 200, width: 240, height: 280)
        let offset = CGPoint(x: -100, y: 120)
        let first = MailboxPlacement.frame(beside: house, screens: [screen], offset: offset)
        let moved = MailboxPlacement.frame(beside: house.offsetBy(dx: 60, dy: 30), screens: [screen], offset: offset)
        XCTAssertEqual(first.origin, CGPoint(x: 300, y: 320))
        XCTAssertEqual(moved.origin, CGPoint(x: 360, y: 350))
        XCTAssertTrue(screen.contains(MailboxPlacement.frame(beside: house.offsetBy(dx: -400, dy: 0), screens: [screen], offset: offset)))
        XCTAssertEqual(MailboxPlacement.frame(beside: house, screens: [screen], offset: offset), first)
    }
    @MainActor func testRelativePositionPersistenceRejectsNonFiniteData() {
        let name = "MailboxPositionTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MailboxPositionStore(defaults: defaults)
        XCTAssertNil(store.offset)
        store.save(CGPoint(x: -90, y: 130))
        XCTAssertEqual(MailboxPositionStore(defaults: defaults).offset, CGPoint(x: -90, y: 130))
        store.save(CGPoint(x: CGFloat.infinity, y: 20))
        XCTAssertEqual(store.offset, CGPoint(x: -90, y: 130))
    }
    func testInboxPlacementKeepsDraggedOffsetWhenMailboxMoves() {
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 1000)
        let mailbox = CGRect(x: 600, y: 300, width: 78, height: 104)
        let size = CGSize(width: 390, height: 452)
        let offset = CGPoint(x: -400, y: -120)
        let initial = MailboxPlacement.inboxFrame(beside: mailbox, size: size, screens: [screen], offset: offset)
        let moved = MailboxPlacement.inboxFrame(beside: mailbox.offsetBy(dx: 90, dy: 80), size: size, screens: [screen], offset: offset)
        XCTAssertEqual(initial.origin, CGPoint(x: 200, y: 180))
        XCTAssertEqual(moved.origin, CGPoint(x: 290, y: 260))
        let edge = MailboxPlacement.inboxFrame(beside: mailbox.offsetBy(dx: -600, dy: 600), size: size, screens: [screen], offset: offset)
        XCTAssertTrue(screen.contains(edge))
        XCTAssertEqual(MailboxPlacement.inboxFrame(beside: mailbox, size: size, screens: [screen], offset: offset), initial)
        XCTAssertTrue(screen.contains(MailboxPlacement.inboxFrame(beside: mailbox, size: size, screens: [screen])))
    }
    func testInboxRestoresDraggedPositionOnAnotherDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1400, height: 1000)
        let secondary = CGRect(x: 1400, y: 0, width: 1400, height: 1000)
        let mailbox = CGRect(x: 600, y: 300, width: 78, height: 104)
        let offset = CGPoint(x: 900, y: -100)
        let result = MailboxPlacement.inboxFrame(beside: mailbox, size: CGSize(width: 390, height: 452), screens: [primary, secondary], offset: offset)
        XCTAssertEqual(result.origin, CGPoint(x: 1500, y: 200))
        XCTAssertTrue(secondary.contains(result))
    }
    @MainActor func testInboxOffsetPersistsSeparatelyFromMailbox() {
        let name = "MailboxInboxPositionTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MailboxPositionStore(defaults: defaults)
        store.save(CGPoint(x: -100, y: 50))
        store.saveInbox(CGPoint(x: 140, y: -220))
        let restored = MailboxPositionStore(defaults: defaults)
        XCTAssertEqual(restored.offset, CGPoint(x: -100, y: 50))
        XCTAssertEqual(restored.inboxOffset, CGPoint(x: 140, y: -220))
    }
    func testAnchorSwitchesSidesAndStaysWithinScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = MailboxPlacement.frame(beside: CGRect(x: 400, y: 100, width: 240, height: 280), screens: [screen])
        XCTAssertGreaterThanOrEqual(right.minX, 640)
        let left = MailboxPlacement.frame(beside: CGRect(x: 760, y: 0, width: 240, height: 280), screens: [screen])
        XCTAssertLessThanOrEqual(left.maxX, 760)
        XCTAssertTrue(screen.contains(left))
        let negative = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        XCTAssertTrue(negative.contains(MailboxPlacement.frame(beside: CGRect(x: -250, y: 500, width: 240, height: 280), screens: [negative, screen])))
    }
}

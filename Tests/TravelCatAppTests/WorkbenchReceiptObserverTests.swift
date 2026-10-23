import Foundation
import XCTest
@testable import TravelCatApp

private final class ReceiptNotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class WorkbenchReceiptObserverTests: XCTestCase {
    func testReplacingAndDetachingObserversStopsPreviousCallbacks() {
        let center = NotificationCenter()
        let name = Notification.Name("receipt-test-only")
        let first = ReceiptNotificationCount(), second = ReceiptNotificationCount()
        let owner = WorkbenchReceiptObservers(center: center)
        owner.replace([center.addObserver(forName: name, object: nil, queue: nil) { _ in first.increment() }])
        center.post(name: name, object: nil)
        XCTAssertEqual(first.value, 1)
        owner.replace([center.addObserver(forName: name, object: nil, queue: nil) { _ in second.increment() }])
        center.post(name: name, object: nil)
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 1)
        owner.removeAll()
        owner.removeAll()
        center.post(name: name, object: nil)
        XCTAssertEqual(second.value, 1)
    }

    func testOwnerReleaseRemovesAttachedObservers() {
        let center = NotificationCenter()
        let name = Notification.Name("receipt-release-test-only")
        let received = ReceiptNotificationCount()
        var owner: WorkbenchReceiptObservers? = WorkbenchReceiptObservers(center: center)
        weak var released = owner
        owner?.replace([center.addObserver(forName: name, object: nil, queue: nil) { _ in received.increment() }])
        center.post(name: name, object: nil)
        XCTAssertEqual(received.value, 1)
        owner = nil
        XCTAssertNil(released)
        center.post(name: name, object: nil)
        XCTAssertEqual(received.value, 1, "Released owners must leave no notification callback registered")
    }
}

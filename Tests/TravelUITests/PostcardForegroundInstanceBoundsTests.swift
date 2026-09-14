import CoreGraphics
import XCTest
@testable import TravelUI

final class PostcardForegroundInstanceBoundsTests: XCTestCase {
    func testFindsEveryInstanceAcrossPaddedRows() throws {
        let labels: [UInt8] = [
            0, 0, 0, 2, 99, 99,
            1, 0, 0, 0, 99, 99,
            1, 1, 0, 0, 99, 99,
        ]

        let rects = try PostcardForegroundInstanceBounds.normalizedRects(
            labels: labels,
            width: 4,
            height: 3,
            bytesPerRow: 6
        )

        XCTAssertEqual(rects, [
            CGRect(x: 0, y: 1.0 / 3.0, width: 0.5, height: 2.0 / 3.0),
            CGRect(x: 0.75, y: 0, width: 0.25, height: 1.0 / 3.0),
        ])
    }

    func testNoInstancesAndMalformedStorageProduceNoForeground() throws {
        XCTAssertEqual(
            try PostcardForegroundInstanceBounds.normalizedRects(
                labels: [0, 0, 0, 0], width: 2, height: 2, bytesPerRow: 2
            ),
            []
        )
        XCTAssertEqual(
            try PostcardForegroundInstanceBounds.normalizedRects(
                labels: [1, 0, 0], width: 2, height: 2, bytesPerRow: 2
            ),
            []
        )
        XCTAssertEqual(
            try PostcardForegroundInstanceBounds.normalizedRects(
                labels: [1, 0, 0, 0], width: 2, height: 2, bytesPerRow: 1
            ),
            []
        )
    }

    func testExcessiveInstanceCountFailsClosedToFullFrameProtection() throws {
        let rects = try PostcardForegroundInstanceBounds.normalizedRects(
            labels: [1, 2, 3, 0],
            width: 4,
            height: 1,
            bytesPerRow: 4,
            maximumInstanceCount: 2
        )

        XCTAssertEqual(rects, [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    func testSingleFullFrameInstanceRemainsFullFrameProtection() throws {
        let rects = try PostcardForegroundInstanceBounds.normalizedRects(
            labels: [1, 1, 1, 1, 1, 1],
            width: 3,
            height: 2,
            bytesPerRow: 3
        )

        XCTAssertEqual(rects, [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    func testScanPropagatesCancellation() {
        XCTAssertThrowsError(try PostcardForegroundInstanceBounds.normalizedRects(
            labels: [1],
            width: 1,
            height: 1,
            bytesPerRow: 1,
            cancellationCheck: { throw CancellationError() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}

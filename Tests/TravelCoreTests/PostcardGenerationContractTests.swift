import XCTest
@testable import TravelCore

final class PostcardGenerationContractTests: XCTestCase {
  func testAcceptsOnlyBoundedLandscapeDimensions() {
    for (width, height) in [(1152, 768), (1536, 1024), (12246, 8164)] {
      XCTAssertTrue(PostcardGenerationContract.accepts(width: width, height: height))
    }
    for (width, height) in [(0, 0), (-3, -2), (768, 512), (1024, 1024), (1024, 1536),
      (1535, 1024), (12249, 8166), (32769, 21846), (Int.max, Int.max)] {
      XCTAssertFalse(PostcardGenerationContract.accepts(width: width, height: height))
    }
    XCTAssertEqual(PostcardGenerationContract.targetWidth, 1536)
    XCTAssertEqual(PostcardGenerationContract.targetHeight, 1024)
  }
}

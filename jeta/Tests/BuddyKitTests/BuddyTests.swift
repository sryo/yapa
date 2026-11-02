import XCTest
import BuddySpec

final class BuddyTests: XCTestCase {
    // R1–R4: every Hardware Buddy spec check in BuddySpec passes; bench/pad counts the same checks.
    func testSpecChecks() {
        for c in specChecks { XCTAssertNil(c.run(), c.name) }
    }
}

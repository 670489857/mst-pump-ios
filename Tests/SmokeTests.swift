import XCTest
@testable import PumpKit

final class SmokeTests: XCTestCase {
    func testPattern() {
        let re = try! NSRegularExpression(pattern: PumpKitInfo.deviceNamePattern)
        let name = "IP1.123456"
        let r = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
        XCTAssertNotNil(r)
    }
}

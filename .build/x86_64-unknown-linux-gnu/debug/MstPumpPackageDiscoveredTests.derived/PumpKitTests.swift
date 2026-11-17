import XCTest
@testable import PumpKitTests

fileprivate extension AppFrameTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__AppFrameTests = [
        ("testBolusFrameLayout", testBolusFrameLayout),
        ("testDecodeRejectsBadCRC", testDecodeRejectsBadCRC),
        ("testRoundTripDecode", testRoundTripDecode),
        ("testStatusParse", testStatusParse),
        ("testStatusWithoutPayloadFrames", testStatusWithoutPayloadFrames),
        ("testTBRPayload", testTBRPayload),
    ]
}

fileprivate extension TwofishTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static let __allTests__TwofishTests = [
        ("test128BitRandomKey", test128BitRandomKey),
        ("test128BitZeroKey", test128BitZeroKey),
        ("test192BitRandomKey", test192BitRandomKey),
        ("test192BitZeroKey", test192BitZeroKey),
        ("test256BitRandomKey", test256BitRandomKey),
        ("test256BitZeroKey", test256BitZeroKey),
        ("testCRC16", testCRC16),
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __PumpKitTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(AppFrameTests.__allTests__AppFrameTests),
        testCase(TwofishTests.__allTests__TwofishTests),
    ]
}
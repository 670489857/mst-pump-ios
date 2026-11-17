import XCTest
@testable import PumpKit

final class TwofishTests: XCTestCase {

    /// 官方测试向量（Twofish 论文附录 / 各类实现的公认向量）
    private func run(_ keyHex: String, _ ptHex: String, _ expectHex: String) {
        let key = Bytes.fromHex(keyHex)!
        let pt = Bytes.fromHex(ptHex)!
        let ct = Twofish(key: key).encryptBlock(pt)
        XCTAssertEqual(Bytes.hex(ct), expectHex)
    }

    func test128BitZeroKey() {
        run("00000000000000000000000000000000",
            "00000000000000000000000000000000",
            "9F589F5CF6122C32B6BFEC2F2AE8C35A")
    }

    func test192BitZeroKey() {
        run("000000000000000000000000000000000000000000000000",
            "00000000000000000000000000000000",
            "EFA71F788965BD4453F860178FC19101")
    }

    func test256BitZeroKey() {
        run("0000000000000000000000000000000000000000000000000000000000000000",
            "00000000000000000000000000000000",
            "57FF739D4DC92C1BD7FC01700CC8216F")
    }

    func test128BitRandomKey() {
        run("A54DCA182530BB1D6D132CDED6237B2E",
            "D91E3F721FCB1971174494D6493C9D5C",
            "712EF037C5B0858ED1E4E7F487E8D549")
    }

    func test192BitRandomKey() {
        run("3460BE31201E69FEDAA0EEE8B9997F5C7C2999FDAFE59325",
            "3CD654AF4DFAD71427A0AEB3FEE9232F",
            "9ABD6B56ED88B361E30D3FA7662D6638")
    }

    func test256BitRandomKey() {
        run("8AF2211F9EE491C5B10BECB5563BFC1E6F93427ECBC8FE2955E5CD8E46DC8ED4",
            "B7C2764D2A5A4D767706F85D8690024A",
            "41DAD1F5EC28B58A6F2E1E1B144044A8")
    }

    func testCRC16() {
        XCTAssertEqual(CRC16.modbus([UInt8]("123456789".utf8)), 0x4B37)
    }
}

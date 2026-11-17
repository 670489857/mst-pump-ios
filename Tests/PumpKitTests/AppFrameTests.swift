import XCTest
@testable import PumpKit

final class AppFrameTests: XCTestCase {

    private func encodeBolus(_ units: Double, msgId: UInt16 = 7) -> [UInt8] {
        AppFrame(rw: .write, cmd: .bolus, serial: "IP4-1234567",
                 payload: PumpCommand.bolus(units), msgId: msgId).encode()
    }

    func testBolusFrameLayout() {
        let frame = encodeBolus(2.5)
        // 2 字节 payload → 整帧 25 字节，len 字段 = 25
        XCTAssertEqual(frame.count, 25)
        XCTAssertEqual(frame[0], 0x55)
        XCTAssertEqual(frame[1], 25)
        XCTAssertEqual(frame[2], 0)
        XCTAssertEqual(frame[3], 0xA1)
        XCTAssertEqual(frame[4], 0x02)      // cmd 0xAA02 低字节
        XCTAssertEqual(frame[5], 0xAA)      // 高字节
        // payload = U × 10 = 25
        XCTAssertEqual(frame[18], 25)
        XCTAssertEqual(frame[19], 0)
        XCTAssertEqual(frame[20], 0x01)     // 标志位
        XCTAssertEqual(frame[21], 7)        // msgId
        XCTAssertEqual(frame[22], 0)
        let crc = CRC16.modbus(Array(frame[0..<23]))
        XCTAssertEqual(frame[23], UInt8(crc & 0xFF))
        XCTAssertEqual(frame[24], UInt8(crc >> 8))
    }

    func testRoundTripDecode() {
        let bytes = encodeBolus(3.0, msgId: 42)
        guard let f = AppFrame.decode(bytes) else { return XCTFail("decode failed") }
        XCTAssertEqual(f.cmd, .bolus)
        XCTAssertEqual(f.rw, .write)
        XCTAssertEqual(f.msgId, 42)
        XCTAssertEqual(f.serial, "IP4-1234567")
        XCTAssertEqual(f.payload, [30, 0])
        XCTAssertTrue(f.crcOK)
        XCTAssertEqual(f.encode(), bytes)
    }

    func testDecodeRejectsBadCRC() {
        var bytes = encodeBolus(1.0)
        bytes[bytes.count - 1] ^= 0xFF
        guard let f = AppFrame.decode(bytes) else { return XCTFail("decode failed") }
        XCTAssertFalse(f.crcOK)
    }

    func testTBRPayload() {
        // 120% / 30 分钟 → 0 | 2 | 12
        XCTAssertEqual(PumpCommand.tbr(percent: 120, minutes: 30), [0, 2, 12])
        XCTAssertEqual(PumpCommand.cancelTBR(), [0, 0, 0])
    }

    func testStatusWithoutPayloadFrames() {
        // 读状态：payload 为空 → 23 字节
        let frame = AppFrame(rw: .read, cmd: .fullStatus, serial: "IP4-1234567",
                             payload: [], msgId: 9).encode()
        XCTAssertEqual(frame.count, 23)
        XCTAssertEqual(frame[3], 0xA3)
        let decoded = AppFrame.decode(frame)
        XCTAssertEqual(decoded?.payload.isEmpty, true)
    }

    func testStatusParse() {
        var payload = [UInt8](repeating: 0, count: 13)
        payload[0] = 0xFF                       // 前导里放点垃圾，确认被跳过
        func push8(_ v: UInt8) { payload.append(v) }
        func push16(_ v: UInt16) {
            payload.append(UInt8(v & 0xFF)); payload.append(UInt8(v >> 8))
        }
        push8(1)      // sysflag
        push8(0)      // errflag
        push8(3)      // drugLevel
        push8(0)      // ucBolusLtd
        push8(48)     // baseSegs
        push8(0)      // tBaseRate
        push8(0)      // tbaseMode
        push8(0)      // pBolusTime
        push8(0)      // timeOffset
        push8(0)      // pulseTime
        push8(0)      // pBolusTBAK
        push8(0)      // tdinnerAlm
        push8(0)      // tcetangAlm
        push8(10)     // insulinCOEF
        push8(10)     // choCOEF
        push8(6)      // targetBlood
        push8(0); push8(0); push8(0)   // lcd / moto / ble
        push16(50)          // maxBase
        push16(1234)        // boxVolume = 123.4 U
        payload.append(contentsOf: [UInt8](repeating: 0, count: 8))  // bolus3
        push16(0); push16(0)
        push16(456)         // dayTotaled = 45.6 U
        push16(10); push16(0); push16(0)
        push16(20); push16(0); push16(100)
        payload.append(contentsOf: [UInt8](repeating: 0, count: 8))
        push16(3)           // battery → 75%

        let status = PumpStatus.parse(payload)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.boxVolume, 123.4)
        XCTAssertEqual(status?.dayTotaled, 45.6)
        XCTAssertEqual(status?.battery, 75)
        XCTAssertEqual(status?.baseSegs, 48)
    }
}

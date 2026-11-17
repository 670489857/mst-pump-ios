import XCTest
@testable import PumpKit

final class PumpDataTests: XCTestCase {

    func testBasalProfileRoundTrip() {
        let rates = (0..<48).map { Double($0) / 40 }        // 0 ... 1.175 U/h
        let bytes = PumpCommand.baseRateTemplate(rates)
        XCTAssertEqual(bytes.count, 96)
        let decoded = BasalProfile.decode(bytes)
        XCTAssertEqual(decoded?.segments.count, 48)
        XCTAssertEqual(decoded?.segments[40] ?? -1, 1.0, accuracy: 0.01)
    }

    func testHistoryRecords() {
        var payload = [UInt8](repeating: 0, count: 13)
        // 两条记录：2026-11-18 10:00:00 / 2.5 U，2026-11-18 12:30:00 / 1.0 U
        func push(_ t: (Int, Int, Int, Int, Int, Int), _ u: Double) {
            payload.append(UInt8(t.0 % 100)); payload.append(UInt8(t.1))
            payload.append(UInt8(t.2)); payload.append(UInt8(t.3))
            payload.append(UInt8(t.4)); payload.append(UInt8(t.5))
            let v = UInt16(u * 10)
            payload.append(UInt8(v & 0xFF)); payload.append(UInt8(v >> 8))
        }
        push((2026, 11, 18, 10, 0, 0), 2.5)
        push((2026, 11, 18, 12, 30, 0), 1.0)

        let recs = HistoryRecord.decodeAll(payload)
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].bolus, 2.5)
        XCTAssertEqual(recs[0].time.year, 2026)
        XCTAssertEqual(recs[1].time.hour, 12)
        XCTAssertEqual(recs[1].bolus, 1.0)
    }

    func testLastBolus() {
        var payload = [UInt8](repeating: 0, count: 13)
        payload += [23, 11, 18, 9, 15, 0, 18]      // 2023 → 自动补 2000 → 2023? 这里 <100 才补
        let b = LastBolus.decode(payload)
        XCTAssertEqual(b?.time.year, 2023)
        XCTAssertEqual(b?.time.minute, 15)
        XCTAssertEqual(b?.bolus ?? 0, 1.8, accuracy: 0.001)
    }

    func testExecutedInfo() {
        var payload = [UInt8](repeating: 0, count: 13)
        payload += [25, 0]                          // 2.5 U
        XCTAssertEqual(ExecutedInfo.decode(payload)?.delivered, 2.5)
    }

    func testBasalState() {
        var payload = [UInt8](repeating: 0, count: 13)
        payload += [23, 11, 18, 9, 0, 0]
        var template = [UInt8]()
        for _ in 0..<48 {
            template.append(100); template.append(0)     // 1.00 U/h
        }
        payload += template
        let s = BasalState.decode(payload)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.profile.segments.first, 1.0)
        XCTAssertGreaterThan(s!.activeRate, 0)
    }

    func testTimeSyncPayload() {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 18; c.hour = 9; c.minute = 5; c.second = 7
        let d = Calendar.current.date(from: c)!
        XCTAssertEqual(PumpCommand.timeSync(d), [26, 11, 18, 9, 5, 7])
    }
}

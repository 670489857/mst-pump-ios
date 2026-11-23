import Foundation

/// 泵的应答帧（实测抓包确认，与下行的 0x55 帧**结构不同**）
///
///   0xAA | len(u16LE, = 整帧字节数) | rw(u8) | cmd(u16LE) | payload | crc16(u16LE)
///
/// 特点：
/// - 帧头是 0xAA（回帧），下行命令才是 0x55
/// - 没有 12 字节 serial，也没有 0x01/msgId 尾
/// - len 直接等于总长度（13 字节的 ACK、83 字节的状态帧）
public struct ReplyFrame {
    public let rw: UInt8
    public let rawCmd: UInt16
    public let payload: [UInt8]
    public let crcOK: Bool

    public var isAck: Bool { rawCmd == 0xAAAA }

    public static func decode(_ bytes: [UInt8]) -> ReplyFrame? {
        guard bytes.count >= 8, bytes[0] == 0xAA else { return nil }
        let len = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard len == bytes.count, len >= 8 else { return nil }
        let rw = bytes[3]
        let cmd = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        let payload = len > 8 ? Array(bytes[6..<(len - 2)]) : []
        let crc = UInt16(bytes[len - 2]) | (UInt16(bytes[len - 1]) << 8)
        let ok = CRC16.modbus(Array(bytes[0..<(len - 2)])) == crc
        return ReplyFrame(rw: rw, rawCmd: cmd, payload: payload, crcOK: ok)
    }
}

/// 设备状态（应答 0xAA00，payload 75 字节，按官方 `handleDeviceInfo` 的偏移解析）
public struct OfficialStatus: Equatable {
    /// 泵内时钟
    public var time: PumpTime
    /// 三餐预设（U）
    public var breakfast: Double
    public var lunch: Double
    public var dinner: Double
    /// 药量剩余（U）
    public var remainingUnits: Double
    /// 今日总量（U）
    public var dayTotaled: Double
    /// 待输注（U）
    public var restBolus: Double
    /// 电量百分比（原始值 ×25）
    public var batteryPercent: Int

    public init(time: PumpTime, breakfast: Double, lunch: Double, dinner: Double,
                remainingUnits: Double, dayTotaled: Double, restBolus: Double,
                batteryPercent: Int) {
        self.time = time
        self.breakfast = breakfast; self.lunch = lunch; self.dinner = dinner
        self.remainingUnits = remainingUnits
        self.dayTotaled = dayTotaled
        self.restBolus = restBolus
        self.batteryPercent = batteryPercent
    }

    /// 官方要求设备信息帧至少 72 字节，短帧直接丢
    public static func decode(_ payload: [UInt8]) -> OfficialStatus? {
        guard payload.count >= 72 else { return nil }
        func u16(_ i: Int) -> Int {
            Int(payload[i]) | (Int(payload[i + 1]) << 8)
        }
        var y = Int(payload[0])
        if y < 100 { y += 2000 }
        let time = PumpTime(year: y, month: Int(payload[1]), day: Int(payload[2]),
                            hour: Int(payload[3]), minute: Int(payload[4]), second: Int(payload[5]))
        return OfficialStatus(
            time: time,
            breakfast: Double(u16(36)) / 10,
            lunch: Double(u16(38)) / 10,
            dinner: Double(u16(40)) / 10,
            remainingUnits: Double(u16(34)) / 10,
            dayTotaled: Double(u16(48)) / 10,
            restBolus: Double(u16(54)) / 10,
            batteryPercent: u16(70) * 25)
    }
}

/// 泵内记录（应答 cmd 低字节=类型，高字节=索引）
/// payload = 6 字节时间 + u16 剂量/数值（×10）+ 3 字节标志
public struct RecordEntry: Equatable {
    public enum Kind: Int {
        case bolus = 1, basal = 2, alarm = 3, prime = 4, reset = 5, daily = 6
        public var title: String {
            switch self {
            case .bolus: return "大剂量"
            case .basal: return "基础率"
            case .alarm: return "报警"
            case .prime: return "排气"
            case .reset: return "复位"
            case .daily: return "每日"
            }
        }
    }

    public var index: Int
    public var kind: Kind
    public var time: PumpTime
    /// 大剂量时为 U，其余类型含义未验证
    public var value: Double
    public var id: String { "\(index)-\(time.text)-\(value)" }

    public static func decode(index: Int, payload: [UInt8]) -> RecordEntry? {
        guard payload.count >= 8, let kind = Kind(rawValue: index & 0xFF) else { return nil }
        var y = Int(payload[0])
        if y < 100 { y += 2000 }
        let time = PumpTime(year: y, month: Int(payload[1]), day: Int(payload[2]),
                            hour: Int(payload[3]), minute: Int(payload[4]), second: Int(payload[5]))
        let raw = Int(payload[6]) | (Int(payload[7]) << 8)
        return RecordEntry(index: index, kind: kind, time: time, value: Double(raw) / 10)
    }
}

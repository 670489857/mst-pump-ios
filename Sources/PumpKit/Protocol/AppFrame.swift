import Foundation

/// 应用层帧（等价原 Java 的 `app_layer/ABytes`）
///
/// 布局（实测自 serialize()）：
///   0x55 | len(u16LE, 整帧字节数) | rw(u8) | cmd(u16LE) | serial(12B ASCII)
///        | payload | 0x01 | msgId(u16LE) | crc16(u16LE)
/// 其中 len = payload.count + 23，CRC 覆盖 CRC 之前的全部字节。
public struct AppFrame {

    public enum RW: UInt8 {
        case write = 0xA1
        case read  = 0xA3
    }

    /// 命令字（原 `app_layer/SCD` 的 Service/Cmd）
    /// 读写命令会复用同一数值（0xAA00/0xAA02），所以用结构体而不是 enum。
    public struct Cmd: RawRepresentable, Equatable, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        // 写
        public static let baseRateTemplate = Cmd(rawValue: 0xAA00)
        public static let bolus            = Cmd(rawValue: 0xAA02)
        public static let tbr              = Cmd(rawValue: 0xAA03)
        public static let timeSync         = Cmd(rawValue: 0xAA04)
        public static let extendedBolus    = Cmd(rawValue: 0xAA05)
        public static let startStop        = Cmd(rawValue: 0xAA06)
        // 读
        public static let fullStatus       = Cmd(rawValue: 0xAA00)
        public static let lastBolus        = Cmd(rawValue: 0x0001)
        public static let lastBaseRate     = Cmd(rawValue: 0x0002)
        public static let alarms           = Cmd(rawValue: 0x0003)
        public static let prime            = Cmd(rawValue: 0x0004)
        public static let history          = Cmd(rawValue: 0xAA01)
        public static let historyDone      = Cmd(rawValue: 0xAA02)
        // 应答
        public static let accOK            = Cmd(rawValue: 0xAA55)
        public static let accError         = Cmd(rawValue: 0xAA5A)
        public static let executing        = Cmd(rawValue: 0xAAA0)
        public static let executed         = Cmd(rawValue: 0xAAAA)
        public static let denied           = Cmd(rawValue: 0xAAA5)
    }

    public let rw: RW
    public let rawCmd: UInt16
    public let serial: String
    public let payload: [UInt8]
    public let msgId: UInt16
    public let crcOK: Bool

    public var cmd: Cmd { Cmd(rawValue: rawCmd) }

    public init(rw: RW, cmd: Cmd, serial: String, payload: [UInt8], msgId: UInt16) {
        self.init(rw: rw, rawCmd: cmd.rawValue, serial: serial,
                  payload: payload, msgId: msgId, crcOK: true)
    }

    private init(rw: RW, rawCmd: UInt16, serial: String,
                 payload: [UInt8], msgId: UInt16, crcOK: Bool) {
        self.rw = rw
        self.rawCmd = rawCmd
        self.serial = serial
        self.payload = payload
        self.msgId = msgId
        self.crcOK = crcOK
    }

    // MARK: - 编码

    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 23)
        out.append(0x55)
        let total = UInt16(payload.count + 23)
        out.append(UInt8(total & 0xFF))
        out.append(UInt8(total >> 8))
        out.append(rw.rawValue)
        out.append(UInt8(rawCmd & 0xFF))
        out.append(UInt8(rawCmd >> 8))
        out.append(contentsOf: ByteBuf.asciiBytes(serial, length: 12))
        out.append(contentsOf: payload)
        out.append(0x01)
        out.append(UInt8(msgId & 0xFF))
        out.append(UInt8(msgId >> 8))
        let crc = CRC16.modbus(out)
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8(crc >> 8))
        return out
    }

    // MARK: - 解码

    public static func decode(_ bytes: [UInt8]) -> AppFrame? {
        guard bytes.count >= 23, bytes[0] == 0x55 else { return nil }
        let len = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard len == bytes.count else { return nil }
        guard let rw = RW(rawValue: bytes[3]) else { return nil }

        let rawCmd = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)

        let serialBytes = Array(bytes[6..<18])
        let serial = String(bytes: serialBytes.filter { $0 != 0 }, encoding: .utf8) ?? ""

        let payloadCount = len - 23
        let payload = payloadCount > 0 ? Array(bytes[18..<(18 + payloadCount)]) : []

        // payload 之后是 1 字节标志位，再是 msgId
        let msgId = UInt16(bytes[19 + payloadCount]) | (UInt16(bytes[20 + payloadCount]) << 8)
        let crc = UInt16(bytes[len - 2]) | (UInt16(bytes[len - 1]) << 8)
        let crcOK = CRC16.modbus(Array(bytes[0..<(len - 2)])) == crc

        return AppFrame(rw: rw, rawCmd: rawCmd, serial: serial,
                        payload: payload, msgId: msgId, crcOK: crcOK)
    }
}

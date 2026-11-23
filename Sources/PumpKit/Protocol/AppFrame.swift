import Foundation

/// 应用层帧（等价原 Java 的 `app_layer/ABytes`）
///
/// 布局（实测自 serialize()）：
///   0x55 | len(u16LE, 整帧字节数) | rw(u8) | cmd(u16LE) | serial(12B ASCII)
///        | payload | 0x01 | msgId(u16LE) | crc16(u16LE)
/// 其中 len = payload.count + 23，CRC 覆盖 CRC 之前的全部字节。
public struct AppFrame {

    /// 两种帧结构：官方 App（默认）/ AAPS demose 驱动（多 3 字节标志+msgId）
    public enum Variant: String, CaseIterable, Identifiable {
        case official = "official"
        case legacy  = "legacy"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .official: return "官方（IP4 App）"
            case .legacy:   return "AAPS demose"
            }
        }
    }

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
    public var variant: Variant = .legacy

    public var cmd: Cmd { Cmd(rawValue: rawCmd) }

    public init(rw: RW, cmd: Cmd, serial: String, payload: [UInt8],
                msgId: UInt16, variant: Variant = .legacy) {
        self.init(rw: rw, rawCmd: cmd.rawValue, serial: serial,
                  payload: payload, msgId: msgId, crcOK: true, variant: variant)
    }

    private init(rw: RW, rawCmd: UInt16, serial: String,
                 payload: [UInt8], msgId: UInt16, crcOK: Bool, variant: Variant) {
        self.variant = variant
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
        let overhead = variant == .official ? 20 : 23
        out.reserveCapacity(payload.count + overhead)
        out.append(0x55)
        let total = UInt16(payload.count + overhead)
        out.append(UInt8(total & 0xFF))
        out.append(UInt8(total >> 8))
        out.append(rw.rawValue)
        out.append(UInt8(rawCmd & 0xFF))
        out.append(UInt8(rawCmd >> 8))
        out.append(contentsOf: Self.serialBytes(serial, variant: variant))
        out.append(contentsOf: payload)
        if variant == .legacy {
            out.append(0x01)
            out.append(UInt8(msgId & 0xFF))
            out.append(UInt8(msgId >> 8))
        }
        let crc = CRC16.modbus(out)
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8(crc >> 8))
        return out
    }

    /// 官方 App 用 0x00 补齐 12 字节；AAPS 帧沿用 0x0D 补齐
    static func serialBytes(_ serial: String, variant: Variant) -> [UInt8] {
        var out = serial.utf8.map { UInt8($0) }
        if out.count > 12 { out = Array(out[0..<12]) }
        while out.count < 12 { out.append(variant == .official ? 0x00 : 0x0D) }
        return out
    }

    // MARK: - 解码

    public static func decode(_ bytes: [UInt8], variant: Variant = .legacy) -> AppFrame? {
        let overhead = variant == .official ? 20 : 23
        guard bytes.count >= overhead, bytes[0] == 0x55 else { return nil }
        let len = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard len == bytes.count else { return nil }
        guard let rw = RW(rawValue: bytes[3]) else { return nil }

        let rawCmd = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)

        let serialBytes = Array(bytes[6..<18])
        let serial = String(bytes: serialBytes.filter { $0 != 0 && $0 != 0x0D }, encoding: .utf8) ?? ""

        let payloadCount = max(0, len - overhead)
        let payload = payloadCount > 0 ? Array(bytes[18..<(18 + payloadCount)]) : []
        var msgId: UInt16 = 0
        if variant == .legacy {
            msgId = UInt16(bytes[19 + payloadCount]) | (UInt16(bytes[20 + payloadCount]) << 8)
        }
        let crc = UInt16(bytes[len - 2]) | (UInt16(bytes[len - 1]) << 8)
        let crcOK = CRC16.modbus(Array(bytes[0..<(len - 2)])) == crc

        return AppFrame(rw: rw, rawCmd: rawCmd, serial: serial,
                        payload: payload, msgId: msgId, crcOK: crcOK, variant: variant)
    }
}


/// 泵序列号的正确取法（官方 App 的做法）
/// 设备名 `IP4.1234567` / `IP4-1234567` → 取分隔符之后那一段，再补到 12 字节
public enum PumpSerial {
    public static func from(deviceName: String) -> String {
        // 设备名里可能带 \r\n（BLE 广播名常见），必须先去干净
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if trimmed.hasPrefix("IP4.") || trimmed.hasPrefix("IP2.") {
            let parts = trimmed.split(separator: ".")
            raw = parts.count >= 2 ? String(parts[1]) : trimmed
        } else {
            let parts = trimmed.split(separator: "-")
            raw = parts.count >= 2 ? String(parts[1]) : trimmed
        }
        // 只保留字母数字，杜绝 CR/LF/空格混进 12 字节
        let cleaned = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let result = String(String.UnicodeScalarView(cleaned))
        return String(result.prefix(12))
    }
}

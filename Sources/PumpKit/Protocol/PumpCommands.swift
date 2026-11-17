import Foundation

/// 打药命令的负载构造（等价原 Java 各 `SATL*Rq` 的 `getData()`）
public enum PumpCommand {

    /// 大剂量：u16 = U × 10
    public static func bolus(_ units: Double) -> [UInt8] {
        let v = UInt16(max(0, min(units * 10, 6553.5)))
        return [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    /// 取消正在输注的大剂量：payload 与 bolus 相同，值传 0
    public static func cancelBolus() -> [UInt8] { bolus(0) }

    /// 临时基础率 TBR：u8 0 | u8 (分钟/15) | u8 (百分比/10)
    public static func tbr(percent: Int, minutes: Int) -> [UInt8] {
        let p = UInt8(max(0, min(percent / 10, 255)))
        let d = UInt8(max(0, min(minutes / 15, 255)))
        return [0, d, p]
    }

    /// 取消 TBR：时长置 0
    public static func cancelTBR() -> [UInt8] { tbr(percent: 0, minutes: 0) }

    /// 方波/双波大剂量：u16 start(U×10) | u16 时长(min) | u16 U×10
    public static func extendedBolus(units: Double, minutes: Int) -> [UInt8] {
        let u = bolus(units)
        let m = UInt16(max(0, min(minutes, 65535)))
        return [u[0], u[1], UInt8(m & 0xFF), UInt8(m >> 8), u[0], u[1]]
    }

    public static func cancelExtendedBolus() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 6)
        out[0] = 1                       // start = 1 表示取消
        return out
    }

    /// 启停：start 0 = 启动输注，1 = 停止
    public static func startStop(stop: Bool) -> [UInt8] { [stop ? 1 : 0] }

    /// 校时：年 | 月 | 日 | 时 | 分 | 秒
    public static func timeSync(_ date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return [UInt8((c.year ?? 2000) % 100), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0)]
    }

    /// 基础率模板：48 × u16，值 = U/h × 100
    public static func baseRateTemplate(_ rates: [Double]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(96)
        for i in 0..<48 {
            let r = i < rates.count ? rates[i] : (rates.last ?? 0)
            let v = UInt16(max(0, min(r * 100, 655.35)))
            out.append(UInt8(v & 0xFF))
            out.append(UInt8(v >> 8))
        }
        return out
    }
}

/// 全状态应答（等价 `GPFSRp`，83 字节）
public struct PumpStatus {
    public var sysflag: UInt8 = 0
    public var errflag: UInt8 = 0
    public var drugLevel: UInt8 = 0
    public var ucBolusLtd: UInt8 = 0
    public var baseSegs: UInt8 = 0
    public var tBaseRate: UInt8 = 0
    public var tbaseMode: UInt8 = 0
    public var pBolusTime: UInt8 = 0
    public var timeOffset: Int8 = 0
    public var pulseTime: UInt8 = 0
    public var pBolusTBAK: UInt8 = 0
    public var tdinnerAlm: UInt8 = 0
    public var tcetangAlm: UInt8 = 0
    public var insulinCOEF: UInt8 = 0
    public var choCOEF: UInt8 = 0
    public var targetBlood: UInt8 = 0
    public var maxBase: UInt16 = 0
    public var boxVolume: Float = 0          // U（已除以 10）
    public var bolus3: [UInt8] = []
    public var tBaseTime: UInt16 = 0
    public var pulseBolus: UInt16 = 0
    public var dayTotaled: Float = 0         // U（已除以 10）
    public var maxBolus: UInt16 = 0
    public var infuseTime: UInt16 = 0
    public var restBolus: UInt16 = 0
    public var uiLowVolume: UInt16 = 0
    public var pulseRef: UInt16 = 0
    public var maxDaily: UInt16 = 0
    public var battery: Int = 0              // 0/25/50/75/100

    /// 解析应答 payload（含 13 字节前导：12 serial + 1 服务字节）
    public static func parse(_ payload: [UInt8]) -> PumpStatus? {
        let buf = ByteBuf(payload)
        buf.shift(13)
        do {
            var s = PumpStatus()
            s.sysflag = try buf.readUInt8()
            s.errflag = try buf.readUInt8()
            s.drugLevel = try buf.readUInt8()
            s.ucBolusLtd = try buf.readUInt8()
            s.baseSegs = try buf.readUInt8()
            s.tBaseRate = try buf.readUInt8()
            s.tbaseMode = try buf.readUInt8()
            s.pBolusTime = try buf.readUInt8()
            s.timeOffset = try buf.readInt8()
            s.pulseTime = try buf.readUInt8()
            s.pBolusTBAK = try buf.readUInt8()
            s.tdinnerAlm = try buf.readUInt8()
            s.tcetangAlm = try buf.readUInt8()
            s.insulinCOEF = try buf.readUInt8()
            s.choCOEF = try buf.readUInt8()
            s.targetBlood = try buf.readUInt8()
            _ = try buf.readUInt8()               // lcdContrast
            _ = try buf.readUInt8()               // motoAlarmClass
            _ = try buf.readUInt8()               // bleRstatus
            s.maxBase = UInt16(try buf.readUInt16LE())
            s.boxVolume = Float(try buf.readUInt16LE()) / 10
            s.bolus3 = try buf.readBytes(8)
            s.tBaseTime = UInt16(try buf.readUInt16LE())
            s.pulseBolus = UInt16(try buf.readUInt16LE())
            s.dayTotaled = Float(try buf.readUInt16LE()) / 10
            s.maxBolus = UInt16(try buf.readUInt16LE())
            s.infuseTime = UInt16(try buf.readUInt16LE())
            s.restBolus = UInt16(try buf.readUInt16LE())
            s.uiLowVolume = UInt16(try buf.readUInt16LE())
            s.pulseRef = UInt16(try buf.readUInt16LE())
            s.maxDaily = UInt16(try buf.readUInt16LE())
            buf.shift(8)
            let raw = try buf.readUInt16LE()
            s.battery = [1: 25, 2: 50, 3: 75, 4: 100][raw] ?? 0
            return s
        } catch {
            return nil
        }
    }
}

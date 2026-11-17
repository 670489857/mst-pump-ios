import Foundation

/// 泵内时钟
public struct PumpTime: Equatable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(year: Int = 2000, month: Int = 1, day: Int = 1,
                hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.year = year; self.month = month; self.day = day
        self.hour = hour; self.minute = minute; self.second = second
    }

    /// 泵里存的是两位年份，读到 < 100 就补 2000
    public static func parse(_ buf: ByteBuf) throws -> PumpTime {
        var y = Int(try buf.readByte())
        if y < 100 { y += 2000 }
        return PumpTime(year: y,
                        month: Int(try buf.readByte()),
                        day: Int(try buf.readByte()),
                        hour: Int(try buf.readByte()),
                        minute: Int(try buf.readByte()),
                        second: Int(try buf.readByte()))
    }

    public var text: String {
        String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    public var date: Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        return Calendar.current.date(from: c)
    }
}

/// 48 段基础率（每段 30 分钟，值 = U/h × 100 存储）
public struct BasalProfile: Equatable {
    public var segments: [Double]      // 48 个，单位 U/h

    public init(segments: [Double]) {
        self.segments = segments
    }

    public static func decode(_ bytes: [UInt8]) -> BasalProfile? {
        guard bytes.count >= 96 else { return nil }
        let buf = ByteBuf(bytes)
        var out: [Double] = []
        out.reserveCapacity(48)
        for _ in 0..<48 {
            guard let raw = try? buf.readUInt16LE() else { return nil }
            out.append(Double(raw) / 100.0)
        }
        return BasalProfile(segments: out)
    }

    public func encode() -> [UInt8] { PumpCommand.baseRateTemplate(segments) }

    public var totalDaily: Double { segments.reduce(0, +) * 0.5 }
}

/// 历史记录里的一条（GHBRp）
public struct HistoryRecord: Identifiable, Equatable {
    public let id = UUID()
    public var time: PumpTime
    public var bolus: Double

    public static func decodeAll(_ payload: [UInt8]) -> [HistoryRecord] {
        let buf = ByteBuf(payload)
        // 应答 payload 前 13 字节是 serial + 服务字节
        buf.shift(13)
        var out: [HistoryRecord] = []
        while buf.size >= 8 {
            guard let t = try? PumpTime.parse(buf),
                  let raw = try? buf.readUInt16LE() else { break }
            out.append(HistoryRecord(time: t, bolus: Double(raw) / 10.0))
        }
        return out
    }
}

/// 最近一次大剂量（GBRp）：时间 + 1 字节（U×10）
public struct LastBolus: Equatable {
    public var time: PumpTime
    public var bolus: Double

    public static func decode(_ payload: [UInt8]) -> LastBolus? {
        let buf = ByteBuf(payload)
        buf.shift(13)
        guard let t = try? PumpTime.parse(buf),
              let raw = try? buf.readByte() else { return nil }
        return LastBolus(time: t, bolus: Double(raw) / 10.0)
    }
}

/// 当前基础率（GBRRp）：时间 + 96 字节 48 段模板
public struct BasalState: Equatable {
    public var time: PumpTime
    public var profile: BasalProfile
    /// 按原驱动算法估算的“当前生效基础率”（近 4 小时加权）
    public var activeRate: Double

    public static func decode(_ payload: [UInt8], now: Date = Date()) -> BasalState? {
        guard payload.count >= 13 + 6 + 96 else { return nil }
        let body = Array(payload[13...])
        let buf = ByteBuf(body)
        guard let t = try? PumpTime.parse(buf) else { return nil }
        guard let profile = BasalProfile.decode(Array(body[6...])) else { return nil }

        // 原实现：从当前时间段往回取 8 段，加权 1, 7/8, 6/8 … 再 /2
        let seconds = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let sod = (seconds.hour ?? 0) * 3600 + (seconds.minute ?? 0) * 60 + (seconds.second ?? 0)
        let index = Int(ceil(Double(sod) / 1800.0))
        var sum = 0.0
        for i in 0..<8 {
            var j = index - i
            if j < 0 { j += 48 }
            sum += profile.segments[j % 48] * (1.0 - Double(i) * 0.125)
        }
        return BasalState(time: t, profile: profile, activeRate: sum / 2.0)
    }
}

/// 应答 0xAAAA「已执行」里带的实际输注量
public struct ExecutedInfo: Equatable {
    public var delivered: Double
    public static func decode(_ payload: [UInt8]) -> ExecutedInfo? {
        let buf = ByteBuf(payload)
        buf.shift(13)
        guard let raw = try? buf.readUInt16LE() else { return nil }
        return ExecutedInfo(delivered: Double(raw) / 10.0)
    }
}

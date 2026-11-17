//
//  CRC16.swift
//  PumpKit
//
//  原实现（Cryptograph.crc16）：init = 65535, poly = 0xA001（反射），无 xorout
//  等价于标准 CRC-16/MODBUS
//

import Foundation

public enum CRC16 {
    public static func modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) & 0xFF
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc = crc >> 1
                }
            }
        }
        return crc
    }

    public static func check(_ bytes: [UInt8], expected: UInt16) -> Bool {
        modbus(bytes) == expected
    }
}

public enum Bytes {
    public static func hex(_ bytes: [UInt8], separator: String = "") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    public static func hex(_ data: Data) -> String {
        hex([UInt8](data))
    }

    public static func fromHex(_ s: String) -> [UInt8]? {
        let clean = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let v = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(v)
            idx = next
        }
        return out
    }
}

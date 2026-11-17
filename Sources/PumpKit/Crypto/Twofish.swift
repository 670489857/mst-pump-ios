//
//  Twofish.swift
//  PumpKit
//
//  Twofish-128（16/24/32 字节密钥），纯 Swift 实现。
//  算法对齐 libtomcrypt twofish.c（Unlicense / public domain），采用预计算 S 表的"大表"变体。
//  官方测试向量见 Tests/PumpKitTests/TwofishTests.swift
//

import Foundation

public final class Twofish {
    public static let blockSize = 16

    private var K = [UInt32](repeating: 0, count: 40)
    private var S = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 4)

    public init(key: [UInt8]) {
        precondition([16, 24, 32].contains(key.count), "Twofish key must be 16/24/32 bytes")
        setup(key)
    }

    public convenience init(key: Data) {
        self.init(key: [UInt8](key))
    }

    // MARK: - tables

    private static let qbox: [[[UInt8]]] = [
        [
            [0x8, 0x1, 0x7, 0xD, 0x6, 0xF, 0x3, 0x2, 0x0, 0xB, 0x5, 0x9, 0xE, 0xC, 0xA, 0x4],
            [0xE, 0xC, 0xB, 0x8, 0x1, 0x2, 0x3, 0x5, 0xF, 0x4, 0xA, 0x6, 0x7, 0x0, 0x9, 0xD],
            [0xB, 0xA, 0x5, 0xE, 0x6, 0xD, 0x9, 0x0, 0xC, 0x8, 0xF, 0x3, 0x2, 0x4, 0x7, 0x1],
            [0xD, 0x7, 0xF, 0x4, 0x1, 0x2, 0x6, 0xE, 0x9, 0xB, 0x3, 0x0, 0x8, 0x5, 0xC, 0xA]
        ],
        [
            [0x2, 0x8, 0xB, 0xD, 0xF, 0x7, 0x6, 0xE, 0x3, 0x1, 0x9, 0x4, 0x0, 0xA, 0xC, 0x5],
            [0x1, 0xE, 0x2, 0xB, 0x4, 0xC, 0x3, 0x7, 0x6, 0xD, 0xA, 0x5, 0xF, 0x9, 0x0, 0x8],
            [0x4, 0xC, 0x7, 0x5, 0x1, 0x6, 0x9, 0xA, 0x0, 0xE, 0xD, 0x8, 0x2, 0xB, 0x3, 0xF],
            [0xB, 0x9, 0x5, 0x1, 0xC, 0x3, 0xD, 0xE, 0x6, 0x4, 0x7, 0xF, 0x2, 0x0, 0x8, 0xA]
        ]
    ]

    private static let rs: [[UInt8]] = [
        [0x01, 0xA4, 0x55, 0x87, 0x5A, 0x58, 0xDB, 0x9E],
        [0xA4, 0x56, 0x82, 0xF3, 0x1E, 0xC6, 0x68, 0xE5],
        [0x02, 0xA1, 0xFC, 0xC1, 0x47, 0xAE, 0x3D, 0x19],
        [0xA4, 0x55, 0x87, 0x5A, 0x58, 0xDB, 0x9E, 0x03]
    ]

    private static let mdsPoly: UInt32 = 0x169
    private static let rsPoly: UInt32 = 0x14D

    private static func sbox(_ i: Int, _ x: UInt32) -> UInt32 {
        let a0 = (x >> 4) & 15
        let b0 = x & 15
        let a1 = a0 ^ b0
        let b1 = (a0 ^ ((b0 << 3) | (b0 >> 1)) ^ (a0 << 3)) & 15
        let a2 = UInt32(qbox[i][0][Int(a1)])
        let b2 = UInt32(qbox[i][1][Int(b1)])
        let a3 = a2 ^ b2
        let b3 = (a2 ^ ((b2 << 3) | (b2 >> 1)) ^ (a2 << 3)) & 15
        let a4 = UInt32(qbox[i][2][Int(a3)])
        let b4 = UInt32(qbox[i][3][Int(b3)])
        return (b4 << 4) + a4
    }

    private static func gfMult(_ a0: UInt32, _ b0: UInt32, _ p: UInt32) -> UInt32 {
        var a = a0
        var result: UInt32 = 0
        var high: UInt32 = b0      // 与 libtomcrypt 一致：不做 8 位截断，
                                   // 让 (high<<1) 的高位与多项式自然抵消
        for _ in 0..<8 {
            if (a & 1) != 0 { result ^= high }
            high = (high >> 7) != 0 ? ((high << 1) ^ p) : (high << 1)
            a >>= 1
        }
        return result & 0xFF
    }

    private static func mdsColumnMult(_ input: UInt8, _ col: Int) -> UInt32 {
        let x01 = UInt32(input)
        let x5B = gfMult(UInt32(input), 0x5B, mdsPoly)
        let xEF = gfMult(UInt32(input), 0xEF, mdsPoly)
        switch col {
        case 0:
            return (x01 << 0) | (x5B << 8) | (xEF << 16) | (xEF << 24)
        case 1:
            return (xEF << 0) | (xEF << 8) | (x5B << 16) | (x01 << 24)
        case 2:
            return (x5B << 0) | (xEF << 8) | (x01 << 16) | (xEF << 24)
        default:
            return (x5B << 0) | (x01 << 8) | (xEF << 16) | (x5B << 24)
        }
    }

    private static func mdsMult(_ input: [UInt8]) -> [UInt8] {
        var tmp: UInt32 = 0
        for x in 0..<4 { tmp ^= mdsColumnMult(input[x], x) }
        return [UInt8(tmp & 0xFF), UInt8((tmp >> 8) & 0xFF), UInt8((tmp >> 16) & 0xFF), UInt8((tmp >> 24) & 0xFF)]
    }

    private static func rsMult(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        for x in 0..<4 {
            var v: UInt32 = 0
            for y in 0..<8 {
                v ^= gfMult(UInt32(input[y]), UInt32(rs[x][y]), rsPoly)
            }
            out[x] = UInt8(v & 0xFF)
        }
        return out
    }

    private static func h(_ input: [UInt8], _ M: [UInt8], _ k: Int, _ offset: Int) -> [UInt8] {
        var y = input
        func s(_ i: Int, _ v: UInt8) -> UInt8 { UInt8(sbox(i, UInt32(v)) & 0xFF) }
        func x(_ i: Int, _ v: UInt8, _ m: UInt8) -> UInt8 { UInt8((sbox(i, UInt32(v)) ^ UInt32(m)) & 0xFF) }

        switch k {
        case 4:
            y[0] = x(1, y[0], M[4 * (6 + offset) + 0])
            y[1] = x(0, y[1], M[4 * (6 + offset) + 1])
            y[2] = x(0, y[2], M[4 * (6 + offset) + 2])
            y[3] = x(1, y[3], M[4 * (6 + offset) + 3])
            fallthrough
        case 3:
            y[0] = x(1, y[0], M[4 * (4 + offset) + 0])
            y[1] = x(1, y[1], M[4 * (4 + offset) + 1])
            y[2] = x(0, y[2], M[4 * (4 + offset) + 2])
            y[3] = x(0, y[3], M[4 * (4 + offset) + 3])
            fallthrough
        case 2:
            y[0] = s(1, x(0, x(0, y[0], M[4 * (2 + offset) + 0]), M[4 * (0 + offset) + 0]))
            y[1] = s(0, x(0, x(1, y[1], M[4 * (2 + offset) + 1]), M[4 * (0 + offset) + 1]))
            y[2] = s(1, x(1, x(0, y[2], M[4 * (2 + offset) + 2]), M[4 * (0 + offset) + 2]))
            y[3] = s(0, x(1, x(1, y[3], M[4 * (2 + offset) + 3]), M[4 * (0 + offset) + 3]))
        default:
            break
        }
        _ = s
        return mdsMult(y)
    }

    private func setup(_ key: [UInt8]) {
        let k = key.count / 8
        var M = [UInt8](repeating: 0, count: 32)
        for i in 0..<key.count { M[i] = key[i] }

        var Sraw = [UInt8](repeating: 0, count: 16)
        for x in 0..<k {
            let r = Twofish.rsMult(Array(M[(x * 8)..<(x * 8 + 8)]))
            for i in 0..<4 { Sraw[x * 4 + i] = r[i] }
        }

        var A: UInt32 = 0
        var B: UInt32 = 0
        for i in 0..<20 {
            let v = UInt8((i + i) & 0xFF)
            let hk = Twofish.h([v, v, v, v], M, k, 0)
            A = UInt32(hk[0]) | (UInt32(hk[1]) << 8) | (UInt32(hk[2]) << 16) | (UInt32(hk[3]) << 24)

            let v2 = UInt8((i + i + 1) & 0xFF)
            let hk2 = Twofish.h([v2, v2, v2, v2], M, k, 1)
            B = rol(UInt32(hk2[0]) | (UInt32(hk2[1]) << 8) | (UInt32(hk2[2]) << 16) | (UInt32(hk2[3]) << 24), 8)

            K[i + i] = A &+ B
            K[i + i + 1] = rol(B &+ B &+ A, 9)
        }

        for i in 0..<256 {
            let t0 = UInt8(Twofish.sbox(0, UInt32(i)) & 0xFF)
            let t1 = UInt8(Twofish.sbox(1, UInt32(i)) & 0xFF)
            if k == 2 {
                S[0][i] = Twofish.mdsColumnMult(sb(1, sb(0, t0 ^ Sraw[0]) ^ Sraw[4]), 0)
                S[1][i] = Twofish.mdsColumnMult(sb(0, sb(0, t1 ^ Sraw[1]) ^ Sraw[5]), 1)
                S[2][i] = Twofish.mdsColumnMult(sb(1, sb(1, t0 ^ Sraw[2]) ^ Sraw[6]), 2)
                S[3][i] = Twofish.mdsColumnMult(sb(0, sb(1, t1 ^ Sraw[3]) ^ Sraw[7]), 3)
            } else if k == 3 {
                S[0][i] = Twofish.mdsColumnMult(sb(1, sb(0, sb(0, t1 ^ Sraw[0]) ^ Sraw[4]) ^ Sraw[8]), 0)
                S[1][i] = Twofish.mdsColumnMult(sb(0, sb(0, sb(1, t1 ^ Sraw[1]) ^ Sraw[5]) ^ Sraw[9]), 1)
                S[2][i] = Twofish.mdsColumnMult(sb(1, sb(1, sb(0, t0 ^ Sraw[2]) ^ Sraw[6]) ^ Sraw[10]), 2)
                S[3][i] = Twofish.mdsColumnMult(sb(0, sb(1, sb(1, t0 ^ Sraw[3]) ^ Sraw[7]) ^ Sraw[11]), 3)
            } else {
                S[0][i] = Twofish.mdsColumnMult(sb(1, sb(0, sb(0, sb(1, t1 ^ Sraw[0]) ^ Sraw[4]) ^ Sraw[8]) ^ Sraw[12]), 0)
                S[1][i] = Twofish.mdsColumnMult(sb(0, sb(0, sb(1, sb(1, t0 ^ Sraw[1]) ^ Sraw[5]) ^ Sraw[9]) ^ Sraw[13]), 1)
                S[2][i] = Twofish.mdsColumnMult(sb(1, sb(1, sb(0, sb(0, t0 ^ Sraw[2]) ^ Sraw[6]) ^ Sraw[10]) ^ Sraw[14]), 2)
                S[3][i] = Twofish.mdsColumnMult(sb(0, sb(1, sb(1, sb(0, t1 ^ Sraw[3]) ^ Sraw[7]) ^ Sraw[11]) ^ Sraw[15]), 3)
            }
        }
    }

    private func sb(_ i: Int, _ v: UInt8) -> UInt8 { UInt8(Twofish.sbox(i, UInt32(v)) & 0xFF) }

    private func rol(_ v: UInt32, _ n: UInt32) -> UInt32 {
        let s = n & 31
        if s == 0 { return v }
        return (v << s) | (v >> (32 - s))
    }

    private func ror(_ v: UInt32, _ n: UInt32) -> UInt32 {
        let s = n & 31
        if s == 0 { return v }
        return (v >> s) | (v << (32 - s))
    }

    private func g(_ x: UInt32) -> UInt32 {
        S[0][Int(x & 0xFF)] ^ S[1][Int((x >> 8) & 0xFF)] ^ S[2][Int((x >> 16) & 0xFF)] ^ S[3][Int((x >> 24) & 0xFF)]
    }

    private func g1(_ x: UInt32) -> UInt32 { g(rol(x, 8)) }

    private func loadLE(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }

    private func storeLE(_ v: UInt32, _ b: inout [UInt8], _ off: Int) {
        b[off] = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
        b[off + 2] = UInt8((v >> 16) & 0xFF)
        b[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    public func encryptBlock(_ pt: [UInt8]) -> [UInt8] {
        precondition(pt.count == 16)
        var a = loadLE(pt, 0) ^ K[0]
        var b = loadLE(pt, 4) ^ K[1]
        var c = loadLE(pt, 8) ^ K[2]
        var d = loadLE(pt, 12) ^ K[3]

        var kIdx = 8
        for _ in 0..<8 {
            let t2 = g1(b)
            let t1 = g(a) &+ t2
            c = ror(c ^ (t1 &+ K[kIdx]), 1)
            d = rol(d, 1) ^ (t2 &+ t1 &+ K[kIdx + 1])

            let t2b = g1(d)
            let t1b = g(c) &+ t2b
            a = ror(a ^ (t1b &+ K[kIdx + 2]), 1)
            b = rol(b, 1) ^ (t2b &+ t1b &+ K[kIdx + 3])
            kIdx += 4
        }

        var ct = [UInt8](repeating: 0, count: 16)
        storeLE(c ^ K[4], &ct, 0)
        storeLE(d ^ K[5], &ct, 4)
        storeLE(a ^ K[6], &ct, 8)
        storeLE(b ^ K[7], &ct, 12)
        return ct
    }
}

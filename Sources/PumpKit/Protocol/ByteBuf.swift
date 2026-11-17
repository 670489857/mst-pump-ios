//
//  ByteBuf.swift
//  PumpKit
//
//  对齐原 Java 实现：info.nightscout.androidaps.plugins.pump.demose.utils.ByteBuf
//  小端序写入 / 顺序读取（带 shift 语义）
//

import Foundation

public struct ByteBufError: Error {}

public final class ByteBuf {
    private var storage: [UInt8]
    private var offset: Int = 0

    public init(capacity: Int) {
        storage = [UInt8](repeating: 0, count: max(0, capacity))
    }

    public init(_ bytes: [UInt8]) {
        storage = bytes
    }

    public var size: Int { storage.count - offset }
    public var isEmpty: Bool { size == 0 }

    // MARK: - 写入

    public func put(_ b: UInt8) {
        storage.append(b)
    }

    public func put(bytes: [UInt8]) {
        storage.append(contentsOf: bytes)
    }

    public func put(_ b: UInt8, count: Int) {
        for _ in 0..<count { storage.append(b) }
    }

    /// u16 little-endian
    public func putUInt16LE(_ v: Int) {
        storage.append(UInt8(v & 0xFF))
        storage.append(UInt8((v >> 8) & 0xFF))
    }

    /// u16 little-endian for UInt16
    public func putUInt16LE(_ v: UInt16) {
        putUInt16LE(Int(v))
    }

    public func putUInt32LE(_ v: Int) {
        storage.append(UInt8(v & 0xFF))
        storage.append(UInt8((v >> 8) & 0xFF))
        storage.append(UInt8((v >> 16) & 0xFF))
        storage.append(UInt8((v >> 24) & 0xFF))
    }

    // MARK: - 读取

    public func readByte() throws -> UInt8 {
        guard offset < storage.count else { throw ByteBufError() }
        let b = storage[offset]
        offset += 1
        return b
    }

    public func readUInt8() throws -> UInt8 { try readByte() }

    public func readInt8() throws -> Int8 {
        let b = try readByte()
        return Int8(bitPattern: b)
    }

    public func readUInt16LE() throws -> Int {
        guard offset + 1 < storage.count else { throw ByteBufError() }
        let lo = Int(storage[offset])
        let hi = Int(storage[offset + 1])
        offset += 2
        return lo | (hi << 8)
    }

    public func readUInt32LE() throws -> Int {
        guard offset + 3 < storage.count else { throw ByteBufError() }
        var v = 0
        for i in 0..<4 { v |= Int(storage[offset + i]) << (8 * i) }
        offset += 4
        return v
    }

    public func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= storage.count else { throw ByteBufError() }
        let slice = Array(storage[offset..<(offset + n)])
        offset += n
        return slice
    }

    public func readRest() throws -> [UInt8] {
        try readBytes(size)
    }

    /// 原实现：把窗口整体左移（丢弃前 offset 字节）
    public func shift(_ n: Int) {
        guard n > 0 else { return }
        let drop = min(n, storage.count - offset)
        offset += drop
    }

    public func bytes() -> [UInt8] { Array(storage[offset...]) }

    public func byte(at index: Int) -> UInt8? {
        let i = offset + index
        guard i >= 0, i < storage.count else { return nil }
        return storage[i]
    }

    public var description: String { Bytes.hex(storage) }

    public static func from(_ bytes: [UInt8]) -> ByteBuf { ByteBuf(bytes) }

    /// ASCII 定长（原 convertStringToAsciiBytes）
    public static func asciiBytes(_ s: String, length: Int) -> [UInt8] {
        var out = s.utf8.map { UInt8($0) }
        if out.count > length { out = Array(out[0..<length]) }
        while out.count < length { out.append(0) }
        return out
    }
}

/// 大端字节写入器。MP4 里所有多字节整数都是大端；
/// `withUnsafeBytes(of: v)` 直接写出来的是小端，这是 Swift 开发者手写 muxer 的第一个坑。
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func u32(_ v: UInt32) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func u64(_ v: UInt64) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    mutating func fourcc(_ s: String) {
        precondition(s.utf8.count == 4, "fourcc 必须正好 4 个字节：\(s)")
        bytes.append(contentsOf: Array(s.utf8))
    }

    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
}

/// 普通 box：先占 4 字节 size，写完 body 再回填
func box(_ type: String, _ body: (inout ByteWriter) -> Void) -> [UInt8] {
    var writer = ByteWriter()
    writer.u32(0)
    writer.fourcc(type)
    body(&writer)
    var out = writer.bytes
    precondition(out.count <= Int(UInt32.max), "box 超过 32 位 size 上限：\(type)")
    out.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(out.count).bigEndian, Array.init))
    return out
}

/// FullBox：在 box 头之后多 1 字节 version + 3 字节 flags
func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0,
             _ body: (inout ByteWriter) -> Void) -> [UInt8] {
    box(type) { writer in
        writer.u32((UInt32(version) << 24) | (flags & 0x00FF_FFFF))
        body(&writer)
    }
}

/// 大端字节读取器。所有读取都做越界检查——解析外部输入时，越界要变成错误，而不是崩溃。
public enum ByteReaderError: Error, Equatable {
    case truncated(at: Int)
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var isAtEnd: Bool { offset == bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= remaining else { throw ByteReaderError.truncated(at: offset) }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
}

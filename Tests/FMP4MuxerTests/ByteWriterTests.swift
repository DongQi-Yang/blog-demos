import XCTest
@testable import FMP4Muxer

final class ByteWriterTests: XCTestCase {
    func test_小端写size会被读成402653184_所以必须大端() {
        // 原文：播放器会把 size = 24 读成 size = 402653184，然后从文件里跳出去
        let littleEndian = withUnsafeBytes(of: UInt32(24).littleEndian, Array.init)
        XCTAssertEqual(littleEndian.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, 402_653_184)

        var writer = ByteWriter()
        writer.u32(24)
        XCTAssertEqual(writer.bytes, [0x00, 0x00, 0x00, 0x18])
    }

    func test_box先占位再回填_size等于整个box的长度() {
        let bytes = box("free") { $0.raw([1, 2, 3, 4]) }
        XCTAssertEqual(bytes, [0, 0, 0, 12, 0x66, 0x72, 0x65, 0x65, 1, 2, 3, 4])
    }

    func test_fullBox的version和flags占4字节且flags只取低24位() {
        let bytes = fullBox("tfhd", version: 1, flags: 0xFF02_0000) { _ in }
        XCTAssertEqual(bytes.count, 12)
        XCTAssertEqual(Array(bytes[8..<12]), [0x01, 0x02, 0x00, 0x00])
    }

    func test_各宽度整数都按大端写出() {
        var writer = ByteWriter()
        writer.u16(0x0102)
        writer.u64(0x0102_0304_0506_0708)
        writer.i16(-1)
        writer.i32(-2)
        XCTAssertEqual(writer.bytes, [1, 2, 1, 2, 3, 4, 5, 6, 7, 8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
    }
}

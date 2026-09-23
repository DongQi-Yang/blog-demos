import Foundation

enum TestSupport {
    /// 包根目录：本文件位于 <root>/Tests/FMP4MuxerTests/TestSupport.swift
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func fixtureBytes() throws -> [UInt8] {
        let url = packageRoot.appendingPathComponent("Fixtures/solid_160x120_30f.h264fix")
        return [UInt8](try Data(contentsOf: url))
    }

    /// 从字节数组的指定位置读一个大端 u32（测试里核对字段值用）
    static func u32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}

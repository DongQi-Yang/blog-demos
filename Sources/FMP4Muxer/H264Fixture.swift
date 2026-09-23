/// 测试码流：由 Scripts/make-h264-fixture.swift 用 VideoToolbox 一次性生成并入库。
/// 格式："H264FIX1" | u16 width | u16 height | u32 fps | u32 frameCount
///       | u16 avcCLength | avcC payload | frameCount × (u8 isSync | u32 size | AVCC bytes)
public struct H264Fixture: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public let isSync: Bool
        /// AVCC 格式：每个 NALU 前有 4 字节大端长度，可直接放进 mdat
        public let bytes: [UInt8]
    }

    public enum ParseError: Error, Equatable {
        case badMagic
        case trailingBytes(Int)
    }

    public let width: UInt16
    public let height: UInt16
    public let fps: UInt32
    /// AVCDecoderConfigurationRecord（avcC box 的 payload，不含 box 头）
    public let avcC: [UInt8]
    public let frames: [Frame]

    public init(bytes: [UInt8]) throws {
        var reader = ByteReader(bytes)
        guard try reader.take(8) == Array("H264FIX1".utf8) else { throw ParseError.badMagic }
        width = try reader.u16()
        height = try reader.u16()
        fps = try reader.u32()
        let frameCount = Int(try reader.u32())
        avcC = try reader.take(Int(try reader.u16()))
        var parsed: [Frame] = []
        parsed.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            let isSync = try reader.u8() == 1
            let size = Int(try reader.u32())
            parsed.append(Frame(isSync: isSync, bytes: try reader.take(size)))
        }
        guard reader.isAtEnd else { throw ParseError.trailingBytes(reader.remaining) }
        frames = parsed
    }
}

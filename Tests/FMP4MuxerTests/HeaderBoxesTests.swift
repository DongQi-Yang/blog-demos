import XCTest
@testable import FMP4Muxer

final class HeaderBoxesTests: XCTestCase {
    private let config = VideoTrackConfig(width: 160, height: 120, avcC: [0x01, 0x42, 0x00, 0x1E, 0xFF, 0xE0, 0x00])

    private func parsedHeader() throws -> [MP4Box] {
        try MP4Inspector.parse(HeaderBoxes.ftyp() + HeaderBoxes.moov(video: config))
    }

    func test_ftyp主品牌是iso5且兼容品牌不含qt() throws {
        let ftyp = try XCTUnwrap(try parsedHeader().find("ftyp"))
        XCTAssertEqual(String(decoding: ftyp.payload[0..<4], as: UTF8.self), "iso5")
        let compatible = stride(from: 8, to: ftyp.payload.count, by: 4)
            .map { String(decoding: ftyp.payload[$0..<$0 + 4], as: UTF8.self) }
        XCTAssertTrue(compatible.contains("iso5"))
        XCTAssertFalse(compatible.contains("qt  "))
    }

    func test_空索引表虽然没有内容但四张都必须存在() throws {
        let stbl = try XCTUnwrap(try parsedHeader().find("moov", "trak", "mdia", "minf", "stbl"))
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: stbl), [])
    }

    func test_tkhd的flags写成7即enabled_in_movie_in_preview() throws {
        let tkhd = try XCTUnwrap(try parsedHeader().find("moov", "trak", "tkhd"))
        XCTAssertEqual(tkhd.fullBoxHeader?.flags, 0x000007)
    }

    func test_mvhd_tkhd_mdhd三个duration在第0秒都填0() throws {
        let top = try parsedHeader()
        let mvhd = try XCTUnwrap(top.find("moov", "mvhd"))
        let tkhd = try XCTUnwrap(top.find("moov", "trak", "tkhd"))
        let mdhd = try XCTUnwrap(top.find("moov", "trak", "mdia", "mdhd"))
        // version 0 布局（payload 含 4 字节 version/flags）：
        // mvhd: creation 4 | modification 8 | timescale 12 | duration 16
        // tkhd: creation 4 | modification 8 | track_ID 12 | reserved 16 | duration 20
        // mdhd: creation 4 | modification 8 | timescale 12 | duration 16
        XCTAssertEqual(TestSupport.u32(mvhd.payload, at: 12), 1_000)     // 先确认字段位置没读错
        XCTAssertEqual(TestSupport.u32(mvhd.payload, at: 16), 0)
        XCTAssertEqual(TestSupport.u32(tkhd.payload, at: 12), 1)
        XCTAssertEqual(TestSupport.u32(tkhd.payload, at: 20), 0)
        XCTAssertEqual(TestSupport.u32(mdhd.payload, at: 12), 90_000)
        XCTAssertEqual(TestSupport.u32(mdhd.payload, at: 16), 0)
    }

    func test_moov里带mvex且trex指向本轨道() throws {
        let trex = try XCTUnwrap(try parsedHeader().find("moov", "mvex", "trex"))
        XCTAssertEqual(TestSupport.u32(trex.payload, at: 4), 1)          // track_ID
    }

    func test_avcC原样放进sample_entry不自己拼() throws {
        let stsd = try XCTUnwrap(try parsedHeader().find("moov", "trak", "mdia", "minf", "stbl", "stsd"))
        let expected = box("avcC") { $0.raw(config.avcC) }
        // avc1 是 stsd 里唯一的 sample entry，avcC 是 avc1 的最后一个子 box
        XCTAssertEqual(Array(stsd.payload.suffix(expected.count)), expected)
    }
}

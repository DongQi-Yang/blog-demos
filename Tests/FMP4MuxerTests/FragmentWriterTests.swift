import XCTest
@testable import FMP4Muxer

final class FragmentWriterTests: XCTestCase {
    private let video = TrackFragment(trackID: 1, baseMediaDecodeTime: 0, samples: [
        Sample(decodeTick: 0, bytes: [UInt8](repeating: 0xAA, count: 100), isSync: true, duration: 3_000),
    ])
    private let audio = TrackFragment(trackID: 2, baseMediaDecodeTime: 0, samples: [
        Sample(decodeTick: 0, bytes: [UInt8](repeating: 0xBB, count: 40), isSync: true, duration: 1_024),
    ])

    private func resolve(_ fragment: [UInt8]) throws -> [MP4Inspector.TrackFragmentData] {
        try MP4Inspector.resolveTrackData(moof: try XCTUnwrap(try MP4Inspector.parse(fragment).find("moof")))
    }

    func test_单轨能播加上第二条轨就坏_tfhd必须设default_base_is_moof() throws {
        // 正确版本：两条轨的基址都是 moof 起始，各自读到自己的字节
        let good = FragmentWriter.fragment(sequence: 1, tracks: [video, audio], baseMode: .defaultBaseIsMoof)
        let goodData = try resolve(good)
        XCTAssertEqual(Array(good[goodData[0].dataStart..<goodData[0].dataStart + 100]), [UInt8](repeating: 0xAA, count: 100))
        XCTAssertEqual(Array(good[goodData[1].dataStart..<goodData[1].dataStart + 40]), [UInt8](repeating: 0xBB, count: 40))

        // 第一版：不设 flag。规范规定第二条 traf 的基址是"上一条 traf 的数据末尾"，
        // 而 data_offset 是按"相对 moof 起始"算的——两者叠加，音频的读取位置被推出了 mdat
        let bad = FragmentWriter.fragment(sequence: 1, tracks: [video, audio], baseMode: .implicit)
        let badData = try resolve(bad)
        XCTAssertEqual(badData[0].dataStart, goodData[0].dataStart)                           // 视频轨：恰好正确
        let endOfVideo = goodData[0].dataStart + 100
        XCTAssertEqual(badData[1].dataStart, endOfVideo + goodData[1].dataStart)             // 音频轨：基址 + 同样的偏移值
        XCTAssertGreaterThan(badData[1].dataStart + 40, bad.count)                            // 读位置已越过文件末尾
    }

    func test_单轨时不设flag也恰好正确_所以这个bug在第一版里永远看不见() throws {
        let good = try resolve(FragmentWriter.fragment(sequence: 1, tracks: [video], baseMode: .defaultBaseIsMoof))
        let bad = try resolve(FragmentWriter.fragment(sequence: 1, tracks: [video], baseMode: .implicit))
        XCTAssertEqual(bad, good)
    }

    func test_trun的sample_flags_关键帧0x02000000_非关键帧0x01010000() throws {
        let track = TrackFragment(trackID: 1, baseMediaDecodeTime: 0, samples: [
            Sample(decodeTick: 0, bytes: [1], isSync: true, duration: 3_000),
            Sample(decodeTick: 3_000, bytes: [2], isSync: false, duration: 3_000),
        ])
        let trun = try XCTUnwrap(try MP4Inspector.parse(FragmentWriter.fragment(sequence: 1, tracks: [track]))
            .find("moof", "traf", "trun"))
        // payload: version/flags 4 | sample_count 4 | data_offset 4 | 每 sample 12 字节（duration, size, flags）
        XCTAssertEqual(TestSupport.u32(trun.payload, at: 4), 2)
        XCTAssertEqual(TestSupport.u32(trun.payload, at: 12 + 8), SampleFlags.sync)
        XCTAssertEqual(TestSupport.u32(trun.payload, at: 24 + 8), SampleFlags.nonSync)
        XCTAssertEqual(SampleFlags.sync, 0x0200_0000)
        XCTAssertEqual(SampleFlags.nonSync, 0x0101_0000)
    }

    func test_tfdt用64位写入baseMediaDecodeTime() throws {
        let track = TrackFragment(trackID: 1, baseMediaDecodeTime: 0x1_0000_0001, samples: video.samples)
        let tfdt = try XCTUnwrap(try MP4Inspector.parse(FragmentWriter.fragment(sequence: 1, tracks: [track]))
            .find("moof", "traf", "tfdt"))
        XCTAssertEqual(tfdt.fullBoxHeader?.version, 1)
        XCTAssertEqual(Array(tfdt.payload[4..<12]), [0, 0, 0, 1, 0, 0, 0, 1])
    }
}

import XCTest
@preconcurrency import AVFoundation
@testable import FMP4Muxer

final class FMP4WriterTests: XCTestCase {
    private func writtenFile() throws -> [UInt8] {
        try FMP4Writer.write(fixture: H264Fixture(bytes: TestSupport.fixtureBytes()))
    }

    func test_产出的fMP4能被AVFoundation完整解码30帧且时长1秒() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data(try writtenFile()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.0001)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)   // await 不能放进 XCTUnwrap 的 autoclosure
        let track = try XCTUnwrap(videoTracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 120))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var decodedFrames = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sampleBuffer) != nil { decodedFrames += 1 }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(decodedFrames, 30)
    }

    func test_分片由关键帧驱动_每个moof都从同步帧开始且tfdt连续() throws {
        let top = try MP4Inspector.parse(try writtenFile())
        let moofs = top.filter { $0.type == "moof" }
        XCTAssertEqual(moofs.count, 3)
        var tfdts: [UInt64] = []
        for moof in moofs {
            let trun = try XCTUnwrap(moof.child("traf")?.child("trun"))
            XCTAssertEqual(TestSupport.u32(trun.payload, at: 4), 10)                    // 每个分片 10 帧
            XCTAssertEqual(TestSupport.u32(trun.payload, at: 12 + 8), SampleFlags.sync)  // 第一帧是同步点
            let tfdt = try XCTUnwrap(moof.child("traf")?.child("tfdt"))
            tfdts.append(tfdt.payload[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
        XCTAssertEqual(tfdts, [0, 30_000, 60_000])
    }

    func test_写出的文件通过严格结构校验且每个分片的数据都落在自己的mdat里() throws {
        let file = try writtenFile()
        let top = try MP4Inspector.parse(file)
        let stbl = try XCTUnwrap(top.find("moov", "trak", "mdia", "minf", "stbl"))
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: stbl), [])
        for (index, moof) in top.enumerated() where moof.type == "moof" {
            let mdat = top[index + 1]
            XCTAssertEqual(mdat.type, "mdat")
            let data = try XCTUnwrap(try MP4Inspector.resolveTrackData(moof: moof).first)
            XCTAssertEqual(data.dataStart, mdat.offset + 8)
            XCTAssertEqual(data.dataStart + data.dataLength, mdat.offset + mdat.size)
        }
    }

    func test_第一帧不是关键帧必须拒绝写出() throws {
        let fixture = try H264Fixture(bytes: TestSupport.fixtureBytes())
        let broken = try H264Fixture(bytes: Self.encode(fixture, dropFirst: 1))   // 从第 1 帧（P 帧）开始
        XCTAssertThrowsError(try FMP4Writer.write(fixture: broken)) {
            XCTAssertEqual($0 as? FMP4Writer.WriteError, .firstFrameNotSync)
        }
    }

    func test_timescale不能被帧率整除时拒绝而不是悄悄截断duration() throws {
        let fixture = try H264Fixture(bytes: TestSupport.fixtureBytes())
        XCTAssertThrowsError(try FMP4Writer.write(fixture: fixture, timescale: 1_000)) {
            XCTAssertEqual($0 as? FMP4Writer.WriteError, .timescaleNotDivisible(timescale: 1_000, fps: 30))
        }
    }

    /// 把 fixture 重新编码成字节（可丢掉前几帧），用来构造非法输入
    private static func encode(_ fixture: H264Fixture, dropFirst: Int) -> [UInt8] {
        var w = ByteWriter()
        w.raw(Array("H264FIX1".utf8))
        w.u16(fixture.width); w.u16(fixture.height); w.u32(fixture.fps)
        let frames = Array(fixture.frames.dropFirst(dropFirst))
        w.u32(UInt32(frames.count))
        w.u16(UInt16(fixture.avcC.count)); w.raw(fixture.avcC)
        for f in frames { w.u8(f.isSync ? 1 : 0); w.u32(UInt32(f.bytes.count)); w.raw(f.bytes) }
        return w.bytes
    }
}

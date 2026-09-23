/// 端到端：把一段已编码的 H.264 写成单视频轨 fMP4。
/// 分片由关键帧驱动（原文第六节）：新关键帧到来时，上一个 GOP 所有 sample 的 duration
/// 都已确定（滞后一帧），正好落成一个从同步帧开始、可独立解码的分片。
public enum FMP4Writer {
    public enum WriteError: Error, Equatable {
        case emptyFixture
        case firstFrameNotSync
        case timescaleNotDivisible(timescale: UInt32, fps: UInt32)
    }

    public static func write(fixture: H264Fixture, timescale: UInt32 = 90_000) throws -> [UInt8] {
        guard let first = fixture.frames.first else { throw WriteError.emptyFixture }
        guard first.isSync else { throw WriteError.firstFrameNotSync }
        guard fixture.fps > 0, timescale % fixture.fps == 0 else {
            throw WriteError.timescaleNotDivisible(timescale: timescale, fps: fixture.fps)
        }

        let config = VideoTrackConfig(width: fixture.width, height: fixture.height,
                                      avcC: fixture.avcC, timescale: timescale)
        let ticksPerFrame = Int64(timescale / fixture.fps)
        var out = HeaderBoxes.ftyp() + HeaderBoxes.moov(video: config)
        var builder = FragmentBuilder()
        var sequence: UInt32 = 1

        func emit(_ samples: [Sample]) {
            guard let head = samples.first else { return }
            out += FragmentWriter.fragment(sequence: sequence, tracks: [
                TrackFragment(trackID: config.trackID, baseMediaDecodeTime: UInt64(head.decodeTick), samples: samples),
            ])
            sequence += 1
        }

        for (index, frame) in fixture.frames.enumerated() {
            try builder.push(Sample(decodeTick: Int64(index) * ticksPerFrame, bytes: frame.bytes, isSync: frame.isSync))
            if frame.isSync { emit(builder.flush()) }   // 关键帧到来：上一个 GOP 的 duration 全部确定
        }
        emit(builder.finish())
        return out
    }
}

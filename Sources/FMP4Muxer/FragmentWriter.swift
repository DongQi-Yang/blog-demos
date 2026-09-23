/// trun 里每个 sample 的 flags（原文第六节）
public enum SampleFlags {
    /// sample_depends_on = 2（不依赖其他帧），sample_is_non_sync = 0（可从此处开始解码）
    public static let sync: UInt32 = 0x0200_0000
    /// sample_depends_on = 1（依赖其他帧），sample_is_non_sync = 1
    public static let nonSync: UInt32 = 0x0101_0000
}

/// tfhd 的基址模式（原文第五节）。
/// `.implicit` 只为复现"单轨能播、加第二条轨就坏"而存在；产品代码永远用 `.defaultBaseIsMoof`。
public enum TfhdBaseMode: Sendable {
    case defaultBaseIsMoof
    case implicit

    var tfhdFlags: UInt32 {
        switch self {
        case .defaultBaseIsMoof: 0x020000
        case .implicit: 0
        }
    }
}

public struct TrackFragment: Sendable {
    public var trackID: UInt32
    public var baseMediaDecodeTime: UInt64
    public var samples: [Sample]

    public init(trackID: UInt32, baseMediaDecodeTime: UInt64, samples: [Sample]) {
        self.trackID = trackID
        self.baseMediaDecodeTime = baseMediaDecodeTime
        self.samples = samples
    }
}

public enum FragmentWriter {
    /// 生成一个 moof + mdat。每条轨的 trun.data_offset 都按"相对 moof 起始"计算，
    /// 这只在 tfhd 声明了 default-base-is-moof 时成立。
    public static func fragment(sequence: UInt32, tracks: [TrackFragment],
                                baseMode: TfhdBaseMode = .defaultBaseIsMoof) -> [UInt8] {
        let trunFlags: UInt32 = 0x000001 | 0x000100 | 0x000200 | 0x000400   // data_offset | duration | size | flags
        let trafs: [[UInt8]] = tracks.map { track in
            box("traf") { w in
                w.raw(fullBox("tfhd", flags: baseMode.tfhdFlags) { $0.u32(track.trackID) })
                w.raw(fullBox("tfdt", version: 1) { $0.u64(track.baseMediaDecodeTime) })
                w.raw(fullBox("trun", flags: trunFlags) { w in
                    w.u32(UInt32(track.samples.count))
                    w.i32(0)                                       // data_offset 占位，下面回填
                    for s in track.samples {
                        w.u32(s.duration)
                        w.u32(UInt32(s.bytes.count))
                        w.u32(s.isSync ? SampleFlags.sync : SampleFlags.nonSync)
                    }
                })
            }
        }
        let mfhd = fullBox("mfhd") { $0.u32(sequence) }
        var moof = box("moof") { w in
            w.raw(mfhd)
            for traf in trafs { w.raw(traf) }
        }

        // data_offset 是固定 4 字节，它的值不影响 moof 大小——所以构建一次、回填即可（"一趟半"）。
        // 它在 traf 内的位置是常量：traf 头 8 + tfhd 16 + tfdt(v1) 20 + trun 头 12 + sample_count 4
        let dataOffsetFieldInTraf = 8 + 16 + 20 + 12 + 4
        var trafStart = 8 + mfhd.count
        var dataOffset = moof.count + 8                             // 第一条轨：moof 大小 + mdat 头
        for (index, track) in tracks.enumerated() {
            precondition(dataOffset <= Int(Int32.max), "data_offset 超出 Int32")
            let at = trafStart + dataOffsetFieldInTraf
            moof.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: Int32(dataOffset).bigEndian, Array.init))
            dataOffset += track.samples.reduce(0) { $0 + $1.bytes.count }
            trafStart += trafs[index].count
        }

        let mdat = box("mdat") { w in
            for track in tracks { for s in track.samples { w.raw(s.bytes) } }   // 按轨顺序连续放
        }
        return moof + mdat
    }
}

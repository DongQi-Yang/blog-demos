/// 单视频轨的配置。avcC 直接用编码器给的 AVCDecoderConfigurationRecord，不要自己拼。
public struct VideoTrackConfig: Equatable, Sendable {
    public var trackID: UInt32
    /// 媒体时间基。90000 能被 24/25/30/60 整除
    public var timescale: UInt32
    public var width: UInt16
    public var height: UInt16
    public var avcC: [UInt8]

    public init(width: UInt16, height: UInt16, avcC: [UInt8], trackID: UInt32 = 1, timescale: UInt32 = 90_000) {
        self.width = width
        self.height = height
        self.avcC = avcC
        self.trackID = trackID
        self.timescale = timescale
    }
}

/// ftyp + moov：在第 0 秒就定死的部分。fMP4 的 moov 只有骨架，索引下放到每个 moof。
enum HeaderBoxes {
    static let unityMatrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

    static func ftyp() -> [UInt8] {
        box("ftyp") { w in
            w.fourcc("iso5")                                    // major brand：default-base-is-moof 从 iso5 起才有
            w.u32(512)                                          // minor version
            for brand in ["isom", "iso5", "iso6", "mp41"] { w.fourcc(brand) }
        }
    }

    static func moov(video: VideoTrackConfig, movieTimescale: UInt32 = 1000) -> [UInt8] {
        box("moov") { w in
            w.raw(mvhd(timescale: movieTimescale, nextTrackID: video.trackID + 1))
            w.raw(box("trak") { w in
                w.raw(tkhd(trackID: video.trackID, width: video.width, height: video.height))
                w.raw(box("mdia") { w in
                    w.raw(mdhd(timescale: video.timescale))
                    w.raw(hdlr())
                    w.raw(box("minf") { w in
                        w.raw(vmhd())
                        w.raw(dinf())
                        w.raw(emptyStbl(sampleEntry: avc1(width: video.width, height: video.height, avcC: video.avcC)))
                    })
                })
            })
            w.raw(box("mvex") { $0.raw(trex(trackID: video.trackID)) })
        }
    }

    // duration 在第 0 秒未知，填 0（合法，表示"未知"）
    static func mvhd(timescale: UInt32, nextTrackID: UInt32) -> [UInt8] {
        fullBox("mvhd") { w in
            w.u32(0); w.u32(0)                  // creation_time, modification_time
            w.u32(timescale)
            w.u32(0)                            // duration
            w.u32(0x0001_0000)                  // rate 1.0
            w.u16(0x0100)                       // volume 1.0
            w.zeros(2 + 8)                      // reserved
            for m in unityMatrix { w.u32(m) }
            w.zeros(6 * 4)                      // pre_defined
            w.u32(nextTrackID)
        }
    }

    // flags 必须是 7（enabled | in_movie | in_preview）；填 0 轨道被标记为不启用，黑屏无声且不报错
    static func tkhd(trackID: UInt32, width: UInt16, height: UInt16) -> [UInt8] {
        fullBox("tkhd", flags: 0x000007) { w in
            w.u32(0); w.u32(0)                  // creation_time, modification_time
            w.u32(trackID)
            w.u32(0)                            // reserved
            w.u32(0)                            // duration
            w.zeros(8)                          // reserved
            w.u16(0); w.u16(0)                  // layer, alternate_group
            w.u16(0)                            // volume（视频轨为 0）
            w.u16(0)                            // reserved
            for m in unityMatrix { w.u32(m) }
            w.u32(UInt32(width) << 16)          // 16.16 定点
            w.u32(UInt32(height) << 16)
        }
    }

    static func mdhd(timescale: UInt32) -> [UInt8] {
        fullBox("mdhd") { w in
            w.u32(0); w.u32(0)                  // creation_time, modification_time
            w.u32(timescale)
            w.u32(0)                            // duration
            w.u16(0x55C4)                       // language = "und"
            w.u16(0)                            // pre_defined
        }
    }

    static func hdlr() -> [UInt8] {
        fullBox("hdlr") { w in
            w.u32(0)                            // pre_defined
            w.fourcc("vide")
            w.zeros(12)                         // reserved
            w.raw(Array("VideoHandler".utf8)); w.u8(0)
        }
    }

    static func vmhd() -> [UInt8] { fullBox("vmhd", flags: 1) { $0.zeros(8) } }

    static func dinf() -> [UInt8] {
        box("dinf") { w in
            w.raw(fullBox("dref") { w in
                w.u32(1)
                w.raw(fullBox("url ", flags: 1) { _ in })   // flags=1：数据就在本文件里
            })
        }
    }

    static func avc1(width: UInt16, height: UInt16, avcC: [UInt8]) -> [UInt8] {
        box("avc1") { w in
            w.zeros(6); w.u16(1)                // reserved, data_reference_index
            w.zeros(2 + 2 + 12)                 // pre_defined, reserved, pre_defined[3]
            w.u16(width); w.u16(height)
            w.u32(0x0048_0000); w.u32(0x0048_0000)   // 72 dpi
            w.u32(0)                            // reserved
            w.u16(1)                            // frame_count
            w.zeros(32)                         // compressorname
            w.u16(0x0018)                       // depth
            w.i16(-1)                           // pre_defined
            w.raw(box("avcC") { $0.raw(avcC) })
        }
    }

    // 四张表虽然是空的，但必须存在：规范定义的是结构完整性，不是信息的有无
    static func emptyStbl(sampleEntry: [UInt8]) -> [UInt8] {
        box("stbl") { w in
            w.raw(fullBox("stsd") { w in w.u32(1); w.raw(sampleEntry) })
            w.raw(fullBox("stts") { $0.u32(0) })
            w.raw(fullBox("stsc") { $0.u32(0) })
            w.raw(fullBox("stsz") { w in w.u32(0); w.u32(0) })
            w.raw(fullBox("stco") { $0.u32(0) })
        }
    }

    // 默认值全填 0，每个分片在 trun 里逐 sample 写完整信息——分片自解释，排查时一眼看全
    static func trex(trackID: UInt32) -> [UInt8] {
        fullBox("trex") { w in
            w.u32(trackID)
            w.u32(1)                            // default_sample_description_index
            w.u32(0); w.u32(0); w.u32(0)        // default duration / size / flags
        }
    }
}

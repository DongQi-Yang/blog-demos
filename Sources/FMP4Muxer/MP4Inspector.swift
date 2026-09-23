/// 一个解析出来的 box。offset 是它在整个文件里的绝对位置——
/// 算数据偏移时要用到，这是"严格读者"和"把 box 当字典读"的区别。
public struct MP4Box: Equatable, Sendable {
    public let type: String
    public let offset: Int
    public let size: Int
    public let children: [MP4Box]
    /// box 头（8 字节）之后的字节；容器 box 为空，内容在 children 里
    public let payload: [UInt8]

    public func child(_ type: String) -> MP4Box? { children.first { $0.type == type } }
    public func children(_ type: String) -> [MP4Box] { children.filter { $0.type == type } }

    /// FullBox 的 version 与 flags（payload 前 4 字节）；payload 不足 4 字节时为 nil
    public var fullBoxHeader: (version: UInt8, flags: UInt32)? {
        guard payload.count >= 4 else { return nil }
        return (payload[0], UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3]))
    }
}

extension Array where Element == MP4Box {
    /// 按路径逐级查找，例如 `find("moov", "trak", "tkhd")`
    public func find(_ path: String...) -> MP4Box? {
        guard let head = path.first, var node = first(where: { $0.type == head }) else { return nil }
        for type in path.dropFirst() {
            guard let next = node.child(type) else { return nil }
            node = next
        }
        return node
    }
}

/// 严格读者：按 ISO/IEC 14496-12 解析，不猜、不容错。
/// 原文第九节：测试一个格式写出器，要用最严格的读者，而不是最宽容的读者。
public enum MP4Inspector {
    public enum InspectError: Error, Equatable {
        case badBoxSize(offset: Int, size: Int)
        case missingBox(String)
        case unsupported(String)
        /// 数据偏移无法表示成文件内的合法位置（超出 Int、加法溢出或为负）
        case badDataOffset(trackID: UInt32)
    }

    /// 需要递归进入的容器 box（本 demo 只写这些）
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "dinf", "stbl", "mvex", "moof", "traf"]

    /// 最大嵌套层数。本 demo 实际最深 5 层（moov/trak/mdia/minf/stbl）；
    /// 不设上限的话，每层 8 字节的恶意输入就能用递归把进程栈打爆。
    static let maxDepth = 16

    public static func parse(_ bytes: [UInt8]) throws -> [MP4Box] {
        try parse(bytes, from: 0, to: bytes.count, depth: 0)
    }

    static func parse(_ bytes: [UInt8], from start: Int, to end: Int, depth: Int) throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var cursor = start
        while cursor < end {
            guard end - cursor >= 8 else { throw InspectError.badBoxSize(offset: cursor, size: end - cursor) }
            let size = Int(bytes[cursor..<cursor + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            // size 0（延伸到文件尾）和 1（64 位 largesize）本 demo 不写，读到即视为非法
            guard size >= 8, size <= end - cursor else { throw InspectError.badBoxSize(offset: cursor, size: size) }
            let type = String(decoding: bytes[cursor + 4..<cursor + 8], as: UTF8.self)
            let bodyStart = cursor + 8, boxEnd = cursor + size
            if containers.contains(type) {
                guard depth < maxDepth else { throw InspectError.unsupported("box 嵌套超过 \(maxDepth) 层") }
                boxes.append(MP4Box(type: type, offset: cursor, size: size,
                                    children: try parse(bytes, from: bodyStart, to: boxEnd, depth: depth + 1),
                                    payload: []))
            } else {
                boxes.append(MP4Box(type: type, offset: cursor, size: size,
                                    children: [], payload: Array(bytes[bodyStart..<boxEnd])))
            }
            cursor = boxEnd
        }
        return boxes
    }

    /// ISO/IEC 14496-12：stbl 必须各含恰好一个 stsd、stts、stsc、stsz（或 stz2）、stco（或 co64）。
    /// 规范定义的是"结构的完整性"，不是"信息的有无"——表是空的也必须在。
    public static func missingSampleTableBoxes(in stbl: MP4Box) -> [String] {
        var missing: [String] = []
        for type in ["stsd", "stts", "stsc"] where stbl.children(type).count != 1 { missing.append(type) }
        if stbl.children("stsz").count + stbl.children("stz2").count != 1 { missing.append("stsz") }
        if stbl.children("stco").count + stbl.children("co64").count != 1 { missing.append("stco") }
        return missing
    }
}

extension MP4Inspector {
    public struct TrackFragmentData: Equatable, Sendable {
        public let trackID: UInt32
        /// 该 traf 第一个 sample 在文件里的绝对偏移
        public let dataStart: Int
        /// 该 traf 所有 sample 的字节数之和
        public let dataLength: Int
    }

    /// 按 ISO/IEC 14496-12 §8.8.7 计算一个 moof 里每条 traf 的数据真正落在文件哪里。
    /// 播放器只信 flags，不信你"以为"的基址：
    /// - tfhd 带 base-data-offset-present（0x000001）：基址是显式写的 64 位绝对偏移
    /// - tfhd 带 default-base-is-moof（0x020000）：基址是 moof 第一个字节
    /// - 都没带：第一条 traf 的基址是 moof 起始，之后每条 traf 的基址是上一条 traf 的数据末尾
    public static func resolveTrackData(moof: MP4Box) throws -> [TrackFragmentData] {
        guard moof.type == "moof" else { throw InspectError.missingBox("moof") }
        var result: [TrackFragmentData] = []
        var previousEnd: Int?
        for traf in moof.children("traf") {
            guard let tfhd = traf.child("tfhd"), let tfhdHeader = tfhd.fullBoxHeader else {
                throw InspectError.missingBox("tfhd")
            }
            guard let trun = traf.child("trun"), let trunHeader = trun.fullBoxHeader else {
                throw InspectError.missingBox("trun")
            }
            guard trunHeader.flags & 0x000200 != 0 else {
                throw InspectError.unsupported("trun 未携带 sample_size，本读者不回退到 tfhd/trex 默认值")
            }

            var tfhdReader = ByteReader(tfhd.payload, offset: 4)
            let trackID = try tfhdReader.u32()
            let base: Int
            if tfhdHeader.flags & 0x000001 != 0 {
                guard let explicit = Int(exactly: try tfhdReader.u64()) else {
                    throw InspectError.badDataOffset(trackID: trackID)
                }
                base = explicit
            } else if tfhdHeader.flags & 0x020000 != 0 {
                base = moof.offset
            } else {
                base = previousEnd ?? moof.offset
            }

            var trunReader = ByteReader(trun.payload, offset: 4)
            let sampleCount = Int(try trunReader.u32())
            let dataOffset = trunHeader.flags & 0x000001 != 0 ? Int(try trunReader.i32()) : 0
            if trunHeader.flags & 0x000004 != 0 { _ = try trunReader.u32() }          // first_sample_flags
            var length = 0
            for _ in 0..<sampleCount {
                if trunHeader.flags & 0x000100 != 0 { _ = try trunReader.u32() }      // duration
                length += Int(try trunReader.u32())                                   // size（上面已确认存在）
                if trunHeader.flags & 0x000400 != 0 { _ = try trunReader.u32() }      // flags
                if trunHeader.flags & 0x000800 != 0 { _ = try trunReader.u32() }      // composition time offset
            }

            // 偏移全部来自文件：任何一步溢出或落到负数都是坏文件，要报错而不是 trap
            let (start, startOverflow) = base.addingReportingOverflow(dataOffset)
            guard !startOverflow, start >= 0 else { throw InspectError.badDataOffset(trackID: trackID) }
            let (end, endOverflow) = start.addingReportingOverflow(length)
            guard !endOverflow else { throw InspectError.badDataOffset(trackID: trackID) }
            result.append(TrackFragmentData(trackID: trackID, dataStart: start, dataLength: length))
            previousEnd = end
        }
        return result
    }
}

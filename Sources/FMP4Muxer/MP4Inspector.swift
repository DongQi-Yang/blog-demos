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
    }

    /// 需要递归进入的容器 box（本 demo 只写这些）
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "dinf", "stbl", "mvex", "moof", "traf"]

    public static func parse(_ bytes: [UInt8]) throws -> [MP4Box] {
        try parse(bytes, from: 0, to: bytes.count)
    }

    static func parse(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [MP4Box] {
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
                boxes.append(MP4Box(type: type, offset: cursor, size: size,
                                    children: try parse(bytes, from: bodyStart, to: boxEnd), payload: []))
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

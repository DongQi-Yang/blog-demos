import XCTest
@testable import FMP4Muxer

final class InspectorTests: XCTestCase {
    func test_容器box递归解析并记录每个box在文件里的绝对偏移() throws {
        let file = box("ftyp") { $0.fourcc("iso5") } + box("moov") { $0.raw(box("free") { $0.raw([9]) }) }
        let top = try MP4Inspector.parse(file)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(top[1].offset, 12)
        XCTAssertEqual(top[1].children.map(\.type), ["free"])
        XCTAssertEqual(top[1].children[0].offset, 20)
        XCTAssertEqual(top[1].children[0].payload, [9])
        XCTAssertEqual(top.find("moov", "free")?.payload, [9])
    }

    func test_box尺寸非法必须报错而不是死循环或越界() {
        // size = 4：小于 box 头本身，按字面前进会原地打转
        XCTAssertThrowsError(try MP4Inspector.parse([0, 0, 0, 4, 0x66, 0x72, 0x65, 0x65])) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badBoxSize(offset: 0, size: 4))
        }
        // size = 99：越过文件末尾
        XCTAssertThrowsError(try MP4Inspector.parse([0, 0, 0, 99, 0x66, 0x72, 0x65, 0x65])) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badBoxSize(offset: 0, size: 99))
        }
        // 剩余字节连一个 box 头都不够
        XCTAssertThrowsError(try MP4Inspector.parse([0, 0, 0])) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badBoxSize(offset: 0, size: 3))
        }
    }

    func test_规范要求stbl里五个必选box各恰好一个_空表也算() throws {
        let complete = box("stbl") { w in
            for t in ["stsd", "stts", "stsc", "stsz", "stco"] { w.raw(fullBox(t) { $0.u32(0) }) }
        }
        let onlyStsd = box("stbl") { w in w.raw(fullBox("stsd") { $0.u32(0) }) }
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: try MP4Inspector.parse(complete)[0]), [])
        XCTAssertEqual(MP4Inspector.missingSampleTableBoxes(in: try MP4Inspector.parse(onlyStsd)[0]),
                       ["stts", "stsc", "stsz", "stco"])
    }

    func test_fullBox头读出version与flags() throws {
        let parsed = try MP4Inspector.parse(fullBox("tkhd", version: 0, flags: 0x000007) { $0.u32(0) })
        XCTAssertEqual(parsed[0].fullBoxHeader?.version, 0)
        XCTAssertEqual(parsed[0].fullBoxHeader?.flags, 0x000007)
    }

    func test_嵌套层数超过上限必须报错而不是栈溢出() {
        // 每层只占 8 字节：80KB 的恶意输入就能嵌套上万层，无上限的递归会把进程栈打爆
        var nested = box("free") { _ in }
        for _ in 0..<40 {
            let inner = nested
            nested = box("moov") { $0.raw(inner) }
        }
        XCTAssertThrowsError(try MP4Inspector.parse(nested)) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .unsupported("box 嵌套超过 16 层"))
        }
    }

    /// 手工构造一个单 traf 的 moof，用来喂给 resolveTrackData 各种恶意偏移
    private func moof(tfhdFlags: UInt32, baseDataOffset: UInt64? = nil, dataOffset: Int32) throws -> MP4Box {
        let bytes = box("moof") { w in
            w.raw(fullBox("mfhd") { $0.u32(1) })
            w.raw(box("traf") { w in
                w.raw(fullBox("tfhd", flags: tfhdFlags) { w in
                    w.u32(7)
                    if let base = baseDataOffset { w.u64(base) }
                })
                w.raw(fullBox("trun", flags: 0x000001 | 0x000200) { w in
                    w.u32(1); w.i32(dataOffset); w.u32(10)
                })
            })
        }
        return try MP4Inspector.parse(bytes)[0]
    }

    func test_base_data_offset超出Int范围必须报错而不是崩溃() throws {
        let m = try moof(tfhdFlags: 0x000001, baseDataOffset: .max, dataOffset: 0)
        XCTAssertThrowsError(try MP4Inspector.resolveTrackData(moof: m)) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badDataOffset(trackID: 7))
        }
    }

    func test_基址加data_offset溢出必须报错而不是崩溃() throws {
        let m = try moof(tfhdFlags: 0x000001, baseDataOffset: UInt64(Int.max), dataOffset: 100)
        XCTAssertThrowsError(try MP4Inspector.resolveTrackData(moof: m)) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badDataOffset(trackID: 7))
        }
    }

    func test_算出负的数据起点必须报错而不是交给调用方越界() throws {
        let m = try moof(tfhdFlags: 0x020000, dataOffset: -100)
        XCTAssertThrowsError(try MP4Inspector.resolveTrackData(moof: m)) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badDataOffset(trackID: 7))
        }
    }

    func test_子box越过父容器但没越过文件也必须报错() {
        // moov 声明 16 字节（只容得下 8 字节内容），里面的 free 却声明 12 字节；
        // 文件总长 24，free 的末尾没越过文件——只看文件边界的解析器会静默解析出一棵错误的树
        var bytes = box("moov") { $0.raw(box("free") { $0.raw([1, 2, 3, 4]) }) }
        bytes.replaceSubrange(0..<4, with: [0, 0, 0, 16])
        bytes += [0, 0, 0, 0]
        XCTAssertEqual(bytes.count, 24)
        XCTAssertThrowsError(try MP4Inspector.parse(bytes)) {
            XCTAssertEqual($0 as? MP4Inspector.InspectError, .badBoxSize(offset: 8, size: 12))
        }
    }
}

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
}

import XCTest
@testable import FMP4Muxer

final class FixtureTests: XCTestCase {
    func test_fixture是30帧160x120且每10帧一个关键帧() throws {
        let fixture = try H264Fixture(bytes: TestSupport.fixtureBytes())
        XCTAssertEqual(fixture.width, 160)
        XCTAssertEqual(fixture.height, 120)
        XCTAssertEqual(fixture.fps, 30)
        XCTAssertEqual(fixture.frames.count, 30)
        XCTAssertEqual(fixture.frames.indices.filter { fixture.frames[$0].isSync }, [0, 10, 20])
        // AVCDecoderConfigurationRecord 的第一个字节 configurationVersion 恒为 1
        XCTAssertEqual(fixture.avcC.first, 0x01)
    }

    func test_截断的fixture必须报错而不是读出半帧() throws {
        let bytes = try TestSupport.fixtureBytes()
        XCTAssertThrowsError(try H264Fixture(bytes: Array(bytes.dropLast(1)))) { error in
            guard case ByteReaderError.truncated = error else {
                return XCTFail("期望 truncated，实际 \(error)")
            }
        }
    }

    func test_魔数不对必须拒绝() throws {
        var bytes = try TestSupport.fixtureBytes()
        bytes[0] = 0x00
        XCTAssertThrowsError(try H264Fixture(bytes: bytes)) { error in
            XCTAssertEqual(error as? H264Fixture.ParseError, .badMagic)
        }
    }

    func test_末尾多出字节必须拒绝() throws {
        let bytes = try TestSupport.fixtureBytes() + [0xFF, 0xFF]
        XCTAssertThrowsError(try H264Fixture(bytes: bytes)) { error in
            XCTAssertEqual(error as? H264Fixture.ParseError, .trailingBytes(2))
        }
    }
}

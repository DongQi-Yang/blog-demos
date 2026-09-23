import XCTest
@testable import FMP4Muxer

final class FragmentBuilderTests: XCTestCase {
    private func sample(_ tick: Int64, sync: Bool = false) -> Sample {
        Sample(decodeTick: tick, bytes: [UInt8(truncatingIfNeeded: tick)], isSync: sync)
    }

    func test_最后一个sample的duration在写它时还不知道_滞后一帧后每个duration都是真实值() throws {
        // 可变帧率：画面静止时，第三帧和第四帧之间隔了 3 秒
        var builder = FragmentBuilder()
        for (i, tick) in [0, 3_000, 6_000, 276_000, 279_000].enumerated() {
            try builder.push(sample(Int64(tick), sync: i == 0))
        }
        XCTAssertEqual(builder.flush().map(\.duration), [3_000, 3_000, 270_000, 3_000])
        XCTAssertTrue(builder.hasPending)   // 最后一帧的 duration 要等下一帧，仍在等待
    }

    func test_解码时间不单调必须拒绝() throws {
        var builder = FragmentBuilder()
        try builder.push(sample(6_000))
        XCTAssertThrowsError(try builder.push(sample(3_000))) {
            XCTAssertEqual($0 as? FragmentBuilder.PushError, .nonMonotonicDecodeTick(previous: 6_000, got: 3_000))
        }
        XCTAssertThrowsError(try builder.push(sample(6_000)))   // 相等也不行：duration 会是 0
    }

    func test_正常结束时最后一帧用最后一个已知duration兜底_即使之前已经flush过() throws {
        var builder = FragmentBuilder()
        try builder.push(sample(0, sync: true))
        try builder.push(sample(3_000))
        try builder.push(sample(9_000))
        XCTAssertEqual(builder.flush().map(\.duration), [3_000, 6_000])   // ready 被取空
        let tail = builder.finish()
        XCTAssertEqual(tail.map(\.decodeTick), [9_000])
        XCTAssertEqual(tail.map(\.duration), [6_000])                      // 不是 1
        XCTAssertFalse(builder.hasPending)
    }

    func test_只有一帧就结束时duration兜底为1() throws {
        var builder = FragmentBuilder()
        try builder.push(sample(0, sync: true))
        XCTAssertEqual(builder.finish().map(\.duration), [1])
    }
}

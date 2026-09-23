import XCTest
@testable import FMP4Muxer

final class TickMathTests: XCTestCase {
    func test_写法B逐个换算duration_30fps录10分钟最坏偏差9000tick即0点1秒() {
        // 帧间隔 33_338_889ns → 3000.50001 tick：每次四舍五入都往同一个方向多出约 0.5 tick
        let pts = (0...18_000).map { Int64($0) * 33_338_889 }
        let truth = TickMath.ticks(fromNanoseconds: pts.last!, timescale: 90_000)
        let a = TickMath.durationsConvertingEachPTS(pts, timescale: 90_000)
        let b = TickMath.durationsConvertingEachDelta(pts, timescale: 90_000)
        XCTAssertEqual(truth, 54_009_000)
        XCTAssertEqual(a.reduce(0, +), truth)          // 写法 A：duration 之和恒等于末帧 PTS 的换算值
        XCTAssertEqual(b.reduce(0, +) - truth, 9_000)  // 写法 B：多出 9000 tick = 0.1 秒
    }

    func test_写法A在任意抖动的可变帧率下duration之和都等于末帧PTS() {
        var state: UInt64 = 42
        var ns: Int64 = 0
        var pts: [Int64] = [0]
        for _ in 0..<5_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407   // 确定性伪随机
            ns += 16_000_000 + Int64(state >> 40)                                     // 16ms ~ 32.7ms 抖动
            pts.append(ns)
        }
        XCTAssertEqual(TickMath.durationsConvertingEachPTS(pts, timescale: 90_000).reduce(0, +),
                       TickMath.ticks(fromNanoseconds: pts.last!, timescale: 90_000))
    }

    func test_纳秒换tick按四舍五入远离零() {
        XCTAssertEqual(TickMath.ticks(fromNanoseconds: 33_333_333, timescale: 90_000), 3_000)   // 2999.99997
        XCTAssertEqual(TickMath.ticks(fromNanoseconds: 33_338_889, timescale: 90_000), 3_001)   // 3000.50001
        XCTAssertEqual(TickMath.ticks(fromNanoseconds: 0, timescale: 90_000), 0)
    }
}

/// tfdt / trun duration 的两种算法（原文第四节）。全程整数，不经过浮点。
public enum TickMath {
    /// 纳秒 → 目标 timescale 的 tick，四舍五入（远离零）。
    /// 适用范围：ns × timescale 不超过 Int64（90kHz 下约 28 小时）
    public static func ticks(fromNanoseconds ns: Int64, timescale: Int64) -> Int64 {
        precondition(ns >= 0 && timescale > 0, "只处理非负时间与正 timescale")
        let (product, overflow) = ns.multipliedReportingOverflow(by: timescale)
        precondition(!overflow, "ns × timescale 溢出 Int64：\(ns) × \(timescale)")
        return (product + 500_000_000) / 1_000_000_000
    }

    /// 写法 A（正确）：先把每个 PTS 相对首帧换算成 tick，再用相邻差做 duration。
    /// 所有 duration 之和恒等于末帧 PTS 的换算值，误差不累积。
    public static func durationsConvertingEachPTS(_ ptsNs: [Int64], timescale: Int64) -> [Int64] {
        guard let t0 = ptsNs.first else { return [] }
        let converted = ptsNs.map { Self.ticks(fromNanoseconds: $0 - t0, timescale: timescale) }
        return zip(converted.dropFirst(), converted).map { $0 - $1 }
    }

    /// 写法 B（错误）：先做相邻差，再逐个换算。每个 duration 各自舍入，误差同向时累积。
    public static func durationsConvertingEachDelta(_ ptsNs: [Int64], timescale: Int64) -> [Int64] {
        zip(ptsNs.dropFirst(), ptsNs).map { Self.ticks(fromNanoseconds: $0 - $1, timescale: timescale) }
    }
}

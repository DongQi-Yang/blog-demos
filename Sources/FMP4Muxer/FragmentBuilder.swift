/// 一个已编码的 sample。duration 由 FragmentBuilder 在下一帧到来时填上。
public struct Sample: Equatable, Sendable {
    public var decodeTick: Int64
    public var duration: UInt32
    public var bytes: [UInt8]
    public var isSync: Bool

    public init(decodeTick: Int64, bytes: [UInt8], isSync: Bool, duration: UInt32 = 0) {
        self.decodeTick = decodeTick
        self.bytes = bytes
        self.isSync = isSync
        self.duration = duration
    }
}

/// 滞后一帧（原文第四节）：一个 sample 的 duration 是它到下一个 sample 的时间差，
/// 收到它的时候下一帧还没来。所以只把"duration 已确定"的 sample 交出去，最后一个留着等。
public struct FragmentBuilder: Sendable {
    public enum PushError: Error, Equatable {
        case nonMonotonicDecodeTick(previous: Int64, got: Int64)
    }

    private var pending: Sample?
    private var ready: [Sample] = []
    private var lastKnownDuration: UInt32?

    public init() {}

    public var hasPending: Bool { pending != nil }

    public mutating func push(_ sample: Sample) throws {
        if var previous = pending {
            guard sample.decodeTick > previous.decodeTick else {
                throw PushError.nonMonotonicDecodeTick(previous: previous.decodeTick, got: sample.decodeTick)
            }
            previous.duration = UInt32(clamping: sample.decodeTick - previous.decodeTick)
            lastKnownDuration = previous.duration
            ready.append(previous)
        }
        pending = sample
    }

    /// 取出 duration 已确定的 sample；pending 的那一个留给下一个分片
    public mutating func flush() -> [Sample] {
        defer { ready.removeAll(keepingCapacity: true) }
        return ready
    }

    /// 正常结束：pending 的真实 duration 无从得知，用最后一个已知的真实 duration 兜底（一帧都没有则为 1）。
    /// 注意兜底值来自 lastKnownDuration 而不是 ready.last——ready 可能刚被 flush 取空。
    public mutating func finish() -> [Sample] {
        if var last = pending {
            last.duration = lastKnownDuration ?? 1
            ready.append(last)
            pending = nil
        }
        return flush()
    }
}
